# Environment preparation is deliberately separate from analysis. Only the anonymous
# project and manifest below are writable; package source locations stay original so
# diagnostics continue to identify the user's files.

function _environment_project_file(path::String)
    isempty(path) && return nothing
    isfile(path) && return abspath(path)
    return Pkg.Types.projectfile_path(abspath(path); strict=true)
end

function _environment_contexts(job::AnalysisJob)
    selected = isempty(job.context.project) ? job.project : job.context.project
    selected_file = _environment_project_file(selected)
    !isempty(selected) && selected_file === nothing &&
        error("No Julia project exists at $(repr(selected))")
    owner_file = _environment_project_file(job.owner)
    files = String[]
    # A nested script environment owns its dependency context. Tests and extensions
    # additionally need their parent package, even when they have their own project.
    parent_context = job.kind in (:package, :extension, :test, :source) || owner_file == selected_file
    parent_context && owner_file !== nothing && push!(files, owner_file)
    selected_file !== nothing && push!(files, selected_file)
    if job.kind === :test && owner_file !== nothing
        test_file = _environment_project_file(joinpath(dirname(owner_file), "test"))
        test_file !== nothing && push!(files, test_file)
    end
    return [Pkg.Types.EnvCache(file) for file in unique(files)]
end

function _environment_fingerprint!(fingerprints::Dict{String,String}, path::String)
    isfile(path) || return
    fingerprints[abspath(path)] = bytes2hex(open(SHA.sha256, path))
    return
end

function _environment_source_inputs!(fingerprints, project_file::String, seen::Set{String})
    project_file = abspath(project_file)
    project_file in seen && return
    push!(seen, project_file)
    _environment_fingerprint!(fingerprints, project_file)
    directory = dirname(project_file)
    for name in Base.preferences_names
        _environment_fingerprint!(fingerprints, joinpath(directory, name))
    end
    project = TOML.parsefile(project_file)
    entryfile = get(project, "path", get(project, "entryfile", nothing))
    entryfile === nothing || _environment_fingerprint!(fingerprints, abspath(directory, entryfile))
    local_manifest = get(project, "manifest", nothing)
    local_manifest = local_manifest === nothing ?
        Pkg.Types.manifestfile_path(directory; strict=true) : abspath(directory, local_manifest)
    local_manifest === nothing || _environment_fingerprint!(fingerprints, local_manifest)
    for source_directory in ("src", "ext", "deps")
        root = joinpath(directory, source_directory)
        isdir(root) || continue
        for (base, _, files) in walkdir(root), file in files
            endswith(file, ".jl") && _environment_fingerprint!(fingerprints, joinpath(base, file))
        end
    end
    # Following a dependency is authorized only by an explicit source path. Never
    # choose a sibling checkout by package name, even when its name looks familiar.
    for source in values(get(project, "sources", Dict()))
        haskey(source, "path") || continue
        child = _environment_project_file(abspath(directory, source["path"]))
        child !== nothing && _environment_source_inputs!(fingerprints, child, seen)
    end
    return
end

function _environment_fingerprints(contexts)
    fingerprints = Dict{String,String}()
    seen = Set{String}()
    for env in contexts
        _environment_source_inputs!(fingerprints, env.project_file, seen)
        _environment_fingerprint!(fingerprints, env.manifest_file)
        for file in keys(env.workspace)
            _environment_source_inputs!(fingerprints, file, seen)
        end
        for entry in values(env.manifest)
            path = entry.path
            path === nothing && continue
            file = _environment_project_file(abspath(dirname(env.manifest_file), path))
            file !== nothing && _environment_source_inputs!(fingerprints, file, seen)
        end
    end
    return fingerprints
end

"Content identity of the dependency context, shared by jobs using the same environment."
function environment_key(job::AnalysisJob)::String
    io = IOBuffer()
    print(io, "JETSweep environment v1\0", VERSION, '\0', Sys.MACHINE, '\0')
    # Test augmentation and trigger sets affect the dependency graph; individual
    # entry points, arguments and setup scripts do not.
    print(io, job.kind === :test ? "test" : "normal", '\0')
    print(io, abspath(isempty(job.context.project) ? job.project : job.context.project), '\0')
    print(io, job.kind in (:test, :extension, :package, :source) ? job.owner : "", '\0')
    for (name, uuid) in sort!(collect(job.triggers); by=first)
        print(io, name, '=', uuid, '\0')
    end
    try
        fingerprints = _environment_fingerprints(_environment_contexts(job))
        for (path, digest) in sort!(collect(fingerprints); by=first)
            print(io, path, '=', digest, '\0')
        end
    catch err
        # Planning a broken project must still yield an identity. Preparation will
        # return the actual failure instead of silently omitting the job.
        print(io, "invalid:", sprint(showerror, err))
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function _environment_merge_dep!(deps, name::String, uuid)
    uuid = string(uuid)
    haskey(deps, name) && deps[name] != uuid &&
        error("Conflicting UUIDs for dependency $name: $(deps[name]) and $uuid")
    deps[name] = uuid
    return
end

function _environment_package_identity(package, description::String)
    # Pkg metadata is mutable and permits incomplete identities. Read each field
    # once, validate it at this boundary, and pass an immutable identity onward.
    name, uuid = package.name, package.uuid
    name isa String || error("$description has no name")
    uuid isa UUID || error("$description ($name) has no UUID")
    return (; name, uuid)
end

function _environment_merge_compat!(compat, name::String, value::String)
    if haskey(compat, name)
        intersection = intersect(Pkg.Types.semver_spec(compat[name]), Pkg.Types.semver_spec(value))
        isempty(intersection) && error("Incompatible constraints for $name: $(compat[name]) and $value")
        # VersionSpec's display encloses disjoint ranges in brackets, which is not
        # valid Project.toml compat syntax. A comma-separated union is valid.
        compat[name] = join(string.(intersection.ranges), ", ")
    else
        compat[name] = value
    end
    return
end

function _environment_source(source, directory::String)
    result = Dict{String,String}(string(k) => string(v) for (k, v) in source)
    if haskey(result, "path")
        # abspath("test", "..") retains a trailing separator on Julia. Drop
        # that lexical difference so a test project's parent source agrees with
        # the same package's own directory, while retaining symlink spellings.
        result["path"] = joinpath(splitpath(abspath(directory, result["path"]))...)
    elseif haskey(result, "url")
        url = result["url"]
        # Pkg accepts local git repositories in url; their relative interpretation
        # must remain tied to the source project after copying the declaration.
        !occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*://|^[^/@:]+@[^/:]+:", url) &&
            (result["url"] = abspath(directory, url))
    end
    return result
end

function _environment_project(job::AnalysisJob, contexts)
    deps = Dict{String,String}()
    preference_bindings = Dict{String,String}()
    compat = Dict{String,String}()
    sources = Dict{String,Dict{String,String}}()
    preferences = Dict{String,Any}()
    workspace = Set{String}()
    preference_files = String[]
    for env in contexts
        append!(preference_files, reverse(Base.get_projects_workspace_to_root(env.project_file)))
    end
    for file in unique(preference_files)
        # Julia implements __clear__, workspace inheritance, exported preferences,
        # and JuliaLocalPreferences precedence here without consulting tool LOAD_PATH.
        preferences = Base.recursive_prefs_merge(preferences, Base.collect_preferences(file, nothing))
    end
    for env in contexts
        raw = TOML.parsefile(env.project_file)
        directory = dirname(env.project_file)
        for (name, uuid) in get(raw, "deps", Dict())
            _environment_merge_dep!(deps, name, uuid)
        end
        for section in ("extras", "weakdeps"), (name, uuid) in get(raw, section, Dict())
            _environment_merge_dep!(preference_bindings, name, uuid)
        end
        if job.kind === :test
            for name in get(get(raw, "targets", Dict()), "test", String[])
                uuid = get(get(raw, "extras", Dict()), name,
                    get(get(raw, "weakdeps", Dict()), name, get(deps, name, nothing)))
                uuid === nothing && error("Test target dependency $name has no declared UUID")
                _environment_merge_dep!(deps, name, uuid)
            end
        end
        package = env.pkg
        if package !== nothing
            identity = _environment_package_identity(package, "Package at $directory")
            _environment_merge_dep!(deps, identity.name, identity.uuid)
            sources[identity.name] = Dict("path" => directory)
        end
        # Includes declarations for extras and extension triggers. They are filtered
        # after all contexts have been merged, rather than discarded prematurely.
        for (name, source) in get(raw, "sources", Dict())
            value = _environment_source(source, directory)
            haskey(sources, name) && sources[name] != value &&
                error("Conflicting explicit sources for dependency $name")
            sources[name] = value
        end
        for (name, value) in get(raw, "compat", Dict())
            _environment_merge_compat!(compat, name, value)
        end
        union!(workspace, dirname.(keys(env.workspace)))
    end
    for (name, uuid) in job.triggers
        _environment_merge_dep!(deps, name, uuid)
    end
    filter!(pair -> haskey(deps, first(pair)), sources)
    filter!(pair -> first(pair) == "julia" || haskey(deps, first(pair)), compat)
    project = Dict{String,Any}("deps" => deps)
    # Preferences may name a transitive dependency through extras/weakdeps.
    # Preserve that UUID binding without promoting it to an active dependency.
    filter!(pair -> !haskey(deps, first(pair)), preference_bindings)
    isempty(preference_bindings) || (project["extras"] = preference_bindings)
    isempty(compat) || (project["compat"] = compat)
    isempty(sources) || (project["sources"] = sources)
    # Let Pkg retain native workspace constraints and explicit member identities.
    # Pkg writes only the active scratch Project and its scratch Manifest.
    isempty(workspace) || (project["workspace"] = Dict("projects" => sort!(collect(workspace))))
    return project, preferences
end

function _environment_absolutize_entry!(entry::Pkg.Types.PackageEntry, manifest_file::String)
    directory = dirname(manifest_file)
    path = entry.path
    path === nothing || (entry.path = abspath(directory, path))
    repo = entry.repo
    source = repo.source
    if source !== nothing && !Pkg.Types.isurl(source)
        repo.source = abspath(directory, source)
    end
    return entry
end

function _environment_seed_manifest(contexts)
    manifest = Pkg.Types.Manifest()
    manifest.manifest_format = v"2.0"
    manifest.julia_version = VERSION
    for env in contexts
        # Julia 1.13 records registry provenance separately from package entries.
        # Keep those records when preserving entries from an existing manifest.
        merge!(manifest.registries, deepcopy(env.manifest.registries))
        for (uuid, original) in env.manifest
            haskey(manifest, uuid) && continue
            manifest[uuid] = _environment_absolutize_entry!(deepcopy(original), env.manifest_file)
        end
    end
    return manifest
end

function _environment_local_entry(file::String)
    project = Pkg.Types.read_project(file)
    identity = _environment_package_identity(project, "Path dependency at $(dirname(file))")
    version = something(project.version, v"0.0.0")
    version isa VersionNumber || error("Path dependency $(identity.name) has no concrete version")
    package = (; identity.name, identity.uuid, version,
        deps=copy(project.deps), sources=deepcopy(project.sources))
    entry = Pkg.Types.PackageEntry(name=package.name, uuid=package.uuid,
        version=package.version, path=dirname(file),
        entryfile=project.entryfile, deps=copy(project.deps),
        weakdeps=copy(project.weakdeps), exts=copy(project.exts))
    return package, entry
end

function _environment_refresh_paths!(manifest, project::Dict, contexts, fingerprints)
    pending = Tuple{String,UUID}[]
    declared = Dict{UUID,Dict{String,String}}()
    root_sources = Set{UUID}()
    for (name, source) in get(project, "sources", Dict())
        uuid = UUID(project["deps"][name])
        declared[uuid] = source
        push!(root_sources, uuid)
    end
    for (name, uuid) in project["deps"]
        push!(pending, (name, UUID(uuid)))
    end
    for env in contexts, (file, member) in env.workspace
        append!(pending, ((name, uuid) for (name, uuid) in member.deps))
        member_uuid, member_name = member.uuid, member.name
        if member_uuid !== nothing && member_name !== nothing
            source = Dict("path" => dirname(file))
            haskey(declared, member_uuid) && declared[member_uuid] != source &&
                error("Conflicting explicit workspace source for $member_name")
            declared[member_uuid] = source
            push!(root_sources, member_uuid)
            push!(pending, (member_name, member_uuid))
        end
        for (name, source) in member.sources
            haskey(member.deps, name) || continue
            uuid = member.deps[name]
            value = _environment_source(source, dirname(file))
            haskey(declared, uuid) && declared[uuid] != value &&
                error("Conflicting explicit workspace source for $name")
            declared[uuid] = value
            push!(root_sources, uuid)
        end
    end
    seen = Set{UUID}()
    while !isempty(pending)
        name, uuid = popfirst!(pending)
        uuid in seen && continue
        push!(seen, uuid)
        old = get(manifest, uuid, nothing)
        source = get(declared, uuid, nothing)
        path = source === nothing ? (old === nothing ? nothing : old.path) : get(source, "path", nothing)
        if path === nothing
            if old === nothing && Pkg.Types.is_stdlib(uuid)
                file = _environment_project_file(Pkg.Types.stdlib_path(name))
                if file !== nothing
                    _, entry = _environment_local_entry(file)
                    entry.path = nothing
                    manifest[uuid] = entry
                    old = entry
                end
            elseif source !== nothing && haskey(source, "url") && old !== nothing && old.path !== nothing
                # An explicit URL replaces a stale developed checkout. Pkg will
                # populate the new exact repository entry during resolution.
                delete!(manifest.deps, uuid)
                old = nothing
            end
            old === nothing || append!(pending, ((name, uuid) for (name, uuid) in old.deps))
            continue
        end
        path = abspath(path)
        file = _environment_project_file(path)
        file === nothing && error("Explicit path dependency $name ($uuid) is unavailable at $path")
        local_project, entry = _environment_local_entry(file)
        local_project.uuid == uuid || error("UUID mismatch for $name at $path: expected $uuid, found $(local_project.uuid)")
        local_project.name == name || error("Package name mismatch at $path: expected $name, found $(local_project.name)")
        manifest[local_project.uuid] = entry
        _environment_fingerprint!(fingerprints, file)
        for (child, source) in local_project.sources
            haskey(local_project.deps, child) || continue
            child_uuid = local_project.deps[child]
            child_uuid in root_sources && continue
            value = _environment_source(source, dirname(file))
            haskey(declared, child_uuid) && declared[child_uuid] != value &&
                error("Conflicting explicit sources for $child ($child_uuid)")
            declared[child_uuid] = value
        end
        append!(pending, ((name, uuid) for (name, uuid) in local_project.deps))
    end
    # A source manifest can contain obsolete or unrelated developed packages.
    # They must not make an otherwise loadable selected context fail preparation.
    filter!(pair -> first(pair) in seen, manifest.deps)
    return manifest
end

function _environment_unavailable(env)
    missing = String[]
    for (name, uuid) in env.project.deps
        Pkg.Types.is_stdlib(uuid) && continue
        haskey(env.manifest, uuid) || push!(missing, "$name ($uuid): absent from the prepared manifest")
    end
    for entry in values(env.manifest), (name, uuid) in entry.deps
        Pkg.Types.is_stdlib(uuid) && continue
        haskey(env.manifest, uuid) || push!(missing, "$name ($uuid): dependency of $(entry.name) is unresolved")
    end
    isempty(missing) || return join(sort!(unique!(missing)), "; ")
    Pkg.Operations.is_instantiated(env, true) || return "Required package sources or artifacts are not installed"
    return ""
end

function _environment_resolve_without_builds!(ctx::Pkg.Types.Context; preserve_exact::Bool=true, download::Bool=true)
    # Pkg.resolve/update eventually call Operations.up, whose last operation runs
    # package build scripts even when a later instantiate disables builds. Use
    # Pkg's native resolution/download stages directly and stop before that step.
    # This uses Pkg 1.13's native stages, not a custom resolver.
    operations = Pkg.Operations
    operations.prune_manifest(ctx.env)
    packages = Pkg.Types.PackageSpec[]
    mode = preserve_exact ? Pkg.PKGMODE_MANIFEST : Pkg.PKGMODE_PROJECT
    level = preserve_exact ? Pkg.UPLEVEL_FIXED : Pkg.UPLEVEL_MAJOR
    Pkg.API.append_all_pkgs!(packages, ctx, mode; workspace=true)
    for package in packages
        Pkg.API.update_source_if_set(ctx.env, package)
        identity = _environment_package_identity(package, "Resolved dependency")
        path, repo = Pkg.Types.get_path_repo(ctx.env.project, ctx.env.project_file,
            ctx.env.manifest_file, identity.name)
        entry = get(ctx.env.manifest, identity.uuid, nothing)
        operations.up_load_versions!(ctx, package, entry, path, repo, level)
    end
    for package in packages
        operations.up_load_manifest_info!(package, get(ctx.env.manifest, package.uuid, nothing))
    end
    preserve = preserve_exact ? Pkg.PRESERVE_NONE : Pkg.PRESERVE_DIRECT
    packages = operations.load_direct_deps(ctx.env, packages; preserve)
    operations.check_registered(ctx.registries, packages)
    dependency_map = operations.resolve_versions!(ctx.env, ctx.registries, packages, ctx.julia_version, false)
    operations.update_manifest!(ctx.env, packages, dependency_map, ctx.julia_version, ctx.registries)
    download && operations.download_source(ctx)
    operations.fixups_from_projectfile!(ctx)
    download && operations.download_artifacts(ctx; julia_version=ctx.julia_version)
    Pkg.Types.write_env(ctx.env; update_undo=false)
    return nothing
end

"Prepare an isolated target environment without modifying source projects or manifests."
function prepare_environment(job::AnalysisJob, directory::String; instantiate::Bool=true)::EnvironmentResult
    directory = abspath(directory)
    fingerprints = Dict{String,String}()
    try
        contexts = _environment_contexts(job)
        merge!(fingerprints, _environment_fingerprints(contexts))
        # Accidental use of an existing target directory must never overwrite it.
        isdir(directory) && !isempty(readdir(directory)) &&
            error("Preparation directory must be empty: $directory")
        mkpath(directory)
        project, preferences = _environment_project(job, contexts)
        manifest = _environment_seed_manifest(contexts)
        _environment_refresh_paths!(manifest, project, contexts, fingerprints)
        project_file = joinpath(directory, "Project.toml")
        open(io -> TOML.print(io, project; sorted=true), project_file, "w")
        isempty(preferences) || open(io -> TOML.print(io, preferences; sorted=true),
            joinpath(directory, "LocalPreferences.toml"), "w")
        env = Pkg.Types.EnvCache(project_file)
        # Newly promoted dependencies may not have manifest entries yet. Supply the
        # partial seed in memory: reading an incomplete manifest from disk would
        # reject it before Pkg gets an opportunity to resolve the missing nodes.
        env.manifest = manifest
        message = ""
        if instantiate
            ctx = Pkg.Types.Context(env=env)
            resolution_seed = deepcopy(env)
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                # Fixed-level resolve retains available manifest versions and also
                # refreshes stale deps/weakdeps/extensions for developed packages.
                try
                    _environment_resolve_without_builds!(ctx)
                catch err
                    err isa Pkg.Resolve.ResolverError || rethrow()
                    message = "Exact manifest versions were incompatible; Pkg re-resolved the isolated environment."
                    ctx.env = deepcopy(resolution_seed)
                    _environment_resolve_without_builds!(ctx; preserve_exact=false)
                end
            end
            env = Pkg.Types.EnvCache(project_file)
        end
        unavailable = _environment_unavailable(env)
        isempty(unavailable) || error("Environment unavailable$(instantiate ? "" : " with instantiate=false"): $unavailable")
        instantiate || Pkg.Types.write_manifest(env.manifest, joinpath(directory, "Manifest.toml"))
        return EnvironmentResult(status=:ready, project=directory,
            load_paths=[directory, "@stdlib"], message=message, fingerprints=fingerprints)
    catch err
        err isa InterruptException && rethrow()
        return EnvironmentResult(status=:failed, project=directory,
            message=sprint(showerror, err), fingerprints=fingerprints)
    end
end
