# Environment preparation. Each context gets a scratch project and manifest under the report
# directory, combining the projects the context names. The analyzed projects, manifests and
# preferences are never written, and package sources stay in place, so diagnostics name the
# original files. Preparation runs in its own process; see `scripts/prepare.jl`.

"Write `data` to `path` as TOML, whole or not at all, since other processes read results."
function _write_toml(path::String, data)
    mkpath(dirname(path))
    partial = path * ".partial"
    open(io -> TOML.print(io, data; sorted=true), partial, "w")
    mv(partial, path; force=true)
    return path
end

"A prepared scratch environment, or the reason it could not be prepared."
struct Environment
    status::Symbol
    dir::String
    message::String
end

ready(environment::Environment) = environment.status === :ready

function _project_file(path::String)
    isempty(path) && return nothing
    isfile(path) && return abspath(path)
    return Pkg.Types.projectfile_path(abspath(path); strict=true)
end

"The projects whose dependencies a context combines, the owning package first."
_context_envs(context::Context) = [Pkg.Types.EnvCache(file) for file in _context_files(context)]

"Names code can load in a context's environment: its projects, their dependencies and triggers."
function _loadable(context::Context)
    names = Set{String}(keys(context.triggers))
    for file in _context_files(context)
        raw = TOML.parsefile(file)
        haskey(raw, "name") && push!(names, raw["name"])
        union!(names, keys(get(raw, "deps", Dict())))
        context.test && union!(names, get(get(raw, "targets", Dict()), "test", String[]))
    end
    return names
end

"The UUID of the package a registry names `name`, if exactly one."
function _registered(name::String)
    uuids = unique!([uuid for registry in Pkg.Registry.reachable_registries()
                     for uuid in Pkg.Registry.uuids_from_name(registry, name)])
    return length(uuids) == 1 ? only(uuids) : nothing
end

function _context_files(context::Context)
    files = String[]
    owner = _project_file(context.owner)
    owner === nothing || push!(files, owner)
    selected = _project_file(context.project)
    isempty(context.project) || selected !== nothing || error("no Julia project at $(context.project)")
    selected === nothing || push!(files, selected)
    if context.test && owner !== nothing
        tests = _project_file(joinpath(dirname(owner), "test"))
        tests === nothing || push!(files, tests)
    end
    return unique!(files)
end

function _merge_dep!(deps::Dict{String,String}, name::String, uuid)
    uuid = string(uuid)
    get(deps, name, uuid) == uuid || error("conflicting UUIDs for $name: $(deps[name]) and $uuid")
    deps[name] = uuid
    return deps
end

_bound(bound) = bound.n == 0 ? "0" : join(bound.t[1:bound.n], ".")
"A version range in compat syntax: Pkg prints ranges in a notation compat reads differently."
_compat(range) = range.upper.n == 0 ? ">= " * _bound(range.lower) : _bound(range.lower) * " - " * _bound(range.upper)

function _merge_compat!(compat::Dict{String,String}, name::String, value::String)
    if haskey(compat, name)
        both = intersect(Pkg.Types.semver_spec(compat[name]), Pkg.Types.semver_spec(value))
        isempty(both) && error("incompatible compat bounds for $name: $(compat[name]) and $value")
        compat[name] = join(_compat.(both.ranges), ", ")
    else
        compat[name] = value
    end
    return compat
end

"Pkg metadata permits missing names and UUIDs; validate them once, at this boundary."
function _identity(package, description::String)
    name, uuid = package.name, package.uuid
    name isa String || error("$description has no name")
    uuid isa UUID || error("$description ($name) has no UUID")
    return (; name, uuid)
end

"A `[sources]` declaration with paths made absolute relative to its project."
function _source(declaration, directory::String)
    source = Dict{String,String}(string(k) => string(v) for (k, v) in declaration)
    if haskey(source, "path")
        source["path"] = _absolute(directory, source["path"])
    elseif haskey(source, "url") && !occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*://|^[^/@:]+@[^/:]+:", source["url"])
        source["url"] = abspath(directory, source["url"])   # a local Git repository
    end
    return source
end

"The scratch Project.toml for a context, and the effective preferences of its projects."
function _scratch_project(context::Context, envs)
    deps, bindings, compat = Dict{String,String}(), Dict{String,String}(), Dict{String,String}()
    sources = Dict{String,Dict{String,String}}()
    workspace = Set{String}()
    preferences = Dict{String,Any}()
    # Julia's own merge implements workspace inheritance, `__clear__` and the precedence
    # of JuliaLocalPreferences.toml over LocalPreferences.toml.
    for file in unique!(reduce(vcat, (reverse(Base.get_projects_workspace_to_root(env.project_file)) for env in envs);
                               init=String[]))
        preferences = Base.recursive_prefs_merge(preferences, Base.collect_preferences(file, nothing))
    end
    for env in envs
        raw = TOML.parsefile(env.project_file)
        directory = dirname(env.project_file)
        foreach(((name, uuid),) -> _merge_dep!(deps, name, uuid), get(raw, "deps", Dict()))
        for section in ("extras", "weakdeps"), (name, uuid) in get(raw, section, Dict())
            _merge_dep!(bindings, name, uuid)
        end
        if context.test
            # Pkg has already rejected test targets that name undeclared packages.
            for name in get(get(raw, "targets", Dict()), "test", String[])
                uuid = get(get(raw, "extras", Dict()), name, get(get(raw, "weakdeps", Dict()), name, get(deps, name, nothing)))
                uuid === nothing || _merge_dep!(deps, name, uuid)
            end
        end
        if env.pkg !== nothing
            package = _identity(env.pkg, "package at $directory")
            _merge_dep!(deps, package.name, package.uuid)
            sources[package.name] = Dict("path" => directory)
        end
        for (name, declaration) in get(raw, "sources", Dict())
            source = _source(declaration, directory)
            get(sources, name, source) == source || error("conflicting [sources] for $name")
            sources[name] = source
        end
        foreach(((name, value),) -> _merge_compat!(compat, name, value), get(raw, "compat", Dict()))
        union!(workspace, dirname.(keys(env.workspace)))
    end
    foreach(((name, uuid),) -> _merge_dep!(deps, name, uuid), context.triggers)
    for (name, directory) in context.imports
        haskey(deps, name) && continue
        if isempty(directory)
            uuid = _registered(name)
            uuid === nothing || _merge_dep!(deps, name, uuid)
        else
            _merge_dep!(deps, name, _identity(Pkg.Types.EnvCache(_project_file(directory)).pkg, "package at $directory").uuid)
            sources[name] = Dict("path" => directory)
        end
    end
    filter!(((name, _),) -> haskey(deps, name), sources)
    filter!(((name, _),) -> name == "julia" || haskey(deps, name), compat)
    # Preferences may name packages through [extras]/[weakdeps]; keep those bindings
    # without promoting the packages to dependencies.
    filter!(((name, _),) -> !haskey(deps, name), bindings)
    project = Dict{String,Any}("deps" => deps)
    isempty(bindings) || (project["extras"] = bindings)
    isempty(compat) || (project["compat"] = compat)
    isempty(sources) || (project["sources"] = sources)
    # Pkg retains native workspace constraints and member identities this way.
    isempty(workspace) || (project["workspace"] = Dict("projects" => sort!(collect(workspace))))
    return project, preferences
end

function _absolute!(entry::Pkg.Types.PackageEntry, manifest_file::String)
    directory = dirname(manifest_file)
    entry.path === nothing || (entry.path = abspath(directory, entry.path))
    source = entry.repo.source
    source === nothing || Pkg.Types.isurl(source) || (entry.repo.source = abspath(directory, source))
    return entry
end

"The existing manifests of a context's projects, merged, as the resolution seed."
function _seed_manifest(envs)
    manifest = Pkg.Types.Manifest()
    manifest.manifest_format = v"2.0"
    manifest.julia_version = VERSION
    for env in envs
        merge!(manifest.registries, deepcopy(env.manifest.registries))
        for (uuid, entry) in env.manifest
            haskey(manifest, uuid) || (manifest[uuid] = _absolute!(deepcopy(entry), env.manifest_file))
        end
    end
    return manifest
end

function _local_entry(file::String)
    project = Pkg.Types.read_project(file)
    package = _identity(project, "path dependency at $(dirname(file))")
    version = something(project.version, v"0.0.0")
    entry = Pkg.Types.PackageEntry(; package.name, package.uuid, version, path=dirname(file),
        project.entryfile, deps=copy(project.deps), weakdeps=copy(project.weakdeps), exts=copy(project.exts))
    return (; package..., deps=project.deps, sources=project.sources), entry
end

"""
Point every path dependency at its declared location and refresh its metadata from its
current Project.toml, since a manifest's copy of it can be stale. Entries nothing reaches
any more are dropped, so an obsolete developed checkout cannot fail preparation.
"""
function _refresh_paths!(manifest, project::Dict, envs)
    declared = Dict{UUID,Dict{String,String}}()
    explicit = Set{UUID}()
    pending = Tuple{String,UUID}[(name, UUID(uuid)) for (name, uuid) in project["deps"]]
    for (name, source) in get(project, "sources", Dict())
        uuid = UUID(project["deps"][name])
        declared[uuid] = source
        push!(explicit, uuid)
    end
    function declare!(uuid, source, name)
        get(declared, uuid, source) == source || error("conflicting sources for $name ($uuid)")
        declared[uuid] = source
    end
    edges(deps) = ((name, uuid) for (name, uuid) in deps)
    for env in envs, (file, member) in env.workspace
        append!(pending, edges(member.deps))
        if member.uuid !== nothing && member.name !== nothing
            declare!(member.uuid, Dict("path" => dirname(file)), member.name)
            push!(explicit, member.uuid)
            push!(pending, (member.name, member.uuid))
        end
        for (name, source) in member.sources
            haskey(member.deps, name) || continue
            declare!(member.deps[name], _source(source, dirname(file)), name)
            push!(explicit, member.deps[name])
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
                file = _project_file(Pkg.Types.stdlib_path(name))
                if file !== nothing
                    _, entry = _local_entry(file)
                    entry.path = nothing
                    manifest[uuid] = old = entry
                end
            elseif source !== nothing && haskey(source, "url") && old !== nothing && old.path !== nothing
                # An explicit URL replaces a stale developed checkout; resolution fills it in.
                delete!(manifest.deps, uuid)
                old = nothing
            end
            old === nothing || append!(pending, edges(old.deps))
            continue
        end
        file = _project_file(abspath(path))
        file === nothing && error("path dependency $name ($uuid) is missing at $path")
        package, entry = _local_entry(file)
        package.uuid == uuid || error("UUID mismatch for $name at $path: expected $uuid, found $(package.uuid)")
        package.name == name || error("package name mismatch at $path: expected $name, found $(package.name)")
        manifest[uuid] = entry
        for (child, child_source) in package.sources
            haskey(package.deps, child) && !(package.deps[child] in explicit) &&
                declare!(package.deps[child], _source(child_source, dirname(file)), child)
        end
        append!(pending, edges(package.deps))
    end
    filter!(((uuid, _),) -> uuid in seen, manifest.deps)
    return manifest
end

function _unavailable(env)
    missing = String[]
    for (name, uuid) in env.project.deps
        Pkg.Types.is_stdlib(uuid) || haskey(env.manifest, uuid) || push!(missing, "$name ($uuid)")
    end
    for entry in values(env.manifest), (name, uuid) in entry.deps
        Pkg.Types.is_stdlib(uuid) || haskey(env.manifest, uuid) || push!(missing, "$name ($uuid), needed by $(entry.name)")
    end
    isempty(missing) || return "unresolved dependencies: " * join(sort!(unique!(missing)), "; ")
    absent = [package.name for package in Pkg.Operations.load_all_deps(env)
              if !Pkg.Operations.is_package_downloaded(env.manifest_file, package)]
    isempty(absent) || return "packages not installed: " * join(sort!(absent), ", ")
    Pkg.Operations.is_instantiated(env, true) || return "package artifacts are not installed"
    return ""
end

"""
Resolve and download with Pkg's own stages, stopping before the build step that
`Pkg.resolve` would run. `exact` keeps the seed manifest's versions.
"""
function _resolve!(ctx::Pkg.Types.Context; exact::Bool, download::Bool)
    ops = Pkg.Operations
    ops.prune_manifest(ctx.env)
    packages = Pkg.Types.PackageSpec[]
    Pkg.API.append_all_pkgs!(packages, ctx, exact ? Pkg.PKGMODE_MANIFEST : Pkg.PKGMODE_PROJECT; workspace=true)
    for package in packages
        identity = _identity(package, "dependency")
        # Pkg looks `[sources]` up by name. They must not reach a private namesake, such as
        # the analyzer's vendored JET when the target develops its own JET.
        if get(ctx.env.project.deps, identity.name, nothing) == identity.uuid
            Pkg.API.update_source_if_set(ctx.env, package)
            path, repo = Pkg.Types.get_path_repo(ctx.env.project, ctx.env.project_file, ctx.env.manifest_file, identity.name)
        else
            package.path, package.repo = nothing, Pkg.Types.GitRepo()
            path, repo = nothing, Pkg.Types.GitRepo()
        end
        ops.up_load_versions!(ctx, package, get(ctx.env.manifest, identity.uuid, nothing), path, repo,
                              exact ? Pkg.UPLEVEL_FIXED : Pkg.UPLEVEL_MAJOR)
    end
    for package in packages
        ops.up_load_manifest_info!(package, get(ctx.env.manifest, package.uuid, nothing))
    end
    packages = ops.load_direct_deps(ctx.env, packages; preserve=exact ? Pkg.PRESERVE_NONE : Pkg.PRESERVE_DIRECT)
    ops.check_registered(ctx.registries, packages)
    dependencies = ops.resolve_versions!(ctx.env, ctx.registries, packages, ctx.julia_version, false)
    ops.update_manifest!(ctx.env, packages, dependencies, ctx.julia_version, ctx.registries)
    download && ops.download_source(ctx)
    ops.fixups_from_projectfile!(ctx)
    download && ops.download_artifacts(ctx; julia_version=ctx.julia_version)
    _supply_revise!(ctx.env.manifest)
    Pkg.Types.write_env(ctx.env; update_undo=false)
    return nothing
end

const _JETLS = UUID("a3b70258-0602-4ee2-b5a6-54c2470400db")
const _JETLSCORE = UUID("8d6afe4c-923b-5912-b63d-b990009c9e74")
const _TESTRUNNER = UUID("65a77010-ae58-5cc9-8243-71cff1cf0f92")
const _REVISE = UUID("295af30f-e4ad-537b-8983-00126c2a3abe")

"""
Make Revise a dependency of JETLSCore, which loads it for its Revise-based package analysis
(`JETLS_DEV_MODE`). JETLS releases leave Revise out of JETLSCore's dependencies, since they
never enable that mode themselves, so JETSweep supplies it.
"""
function _supply_revise!(manifest)
    core = get(manifest, _JETLSCORE, nothing)
    core === nothing || !haskey(manifest, _REVISE) || (core.deps["Revise"] = _REVISE)
    return manifest
end

function _entry_source(entry::Pkg.Types.PackageEntry, manifest_file::String)
    entry.path === nothing || return Dict("path" => abspath(dirname(manifest_file), entry.path))
    repo = entry.repo
    repo.source === nothing && return nothing
    source = Dict("url" => repo.source, "rev" => something(repo.rev, string(entry.tree_hash)))
    repo.subdir === nothing || (source["subdir"] = repo.subdir)
    return source
end

"""
Fail unless the project JETSweep was loaded from has the analyzer installed, which a
checkout lacks until it is instantiated.
"""
function _require_tool()
    tool = Pkg.Types.EnvCache(tool_project())
    all(uuid -> haskey(tool.manifest, uuid), (_JETLS, _TESTRUNNER, _REVISE)) && Pkg.Operations.is_instantiated(tool) &&
        return nothing
    directory = Base.shell_escape(dirname(tool.project_file))
    error("JETSweep's project $directory is not instantiated; run ",
          "`julia --project=$directory -e 'using Pkg; Pkg.instantiate()'` first")
end

"""
Add the analyzer to a scratch environment: JETLS with its Revise-based package analysis
enabled, TestRunner, which JETLS requires as a direct dependency, and Revise, which that
analysis needs (see `_supply_revise!`). Resolving tool and target together gives packages
they share one version for both: the target keeps a Revise it locks if it is of the series
the analyzer uses, whose release JETSweep pins.
"""
function _add_tool!(project::Dict, preferences::Dict, manifest)
    tool = Pkg.Types.EnvCache(tool_project())
    for (uuid, entry) in tool.manifest
        haskey(manifest, uuid) || (manifest[uuid] = _absolute!(deepcopy(entry), tool.manifest_file))
    end
    mergewith!((a, _) -> a, manifest.registries, deepcopy(tool.manifest.registries))
    sources = get!(project, "sources", Dict{String,Dict{String,String}}())
    for uuid in (_JETLS, _TESTRUNNER, _REVISE)
        entry = tool.manifest[uuid]
        _merge_dep!(project["deps"], entry.name, uuid)
        source = _entry_source(entry, tool.manifest_file)
        source === nothing || haskey(sources, entry.name) || (sources[entry.name] = source)
    end
    revise = tool.manifest[_REVISE].version
    _merge_compat!(get!(project, "compat", Dict{String,String}()), "Revise", "$(revise.major).$(revise.minor)")
    get!(project, "extras", Dict{String,String}())["JETLSCore"] = string(_JETLSCORE)
    preferences["JETLSCore"] = merge(get(preferences, "JETLSCore", Dict{String,Any}()), Dict("JETLS_DEV_MODE" => true))
    # Pkg applies root compat bounds by name, which would also constrain JETLS's privately
    # vendored namesakes, such as its own JET. Check those bounds after resolution instead.
    named = merge(project["deps"], get(project, "extras", Dict{String,String}()))
    compat = get(project, "compat", Dict{String,String}())
    deferred = Dict{String,String}()
    for (name, bound) in collect(compat)
        name == "julia" && continue
        any(entry -> entry.name == name && string(entry.uuid) != get(named, name, ""), values(manifest)) &&
            (deferred[name] = pop!(compat, name))
    end
    return deferred
end

function _check_deferred(env, deferred::Dict{String,String})
    for (name, bound) in deferred
        uuid = get(env.project.deps, name, nothing)
        uuid === nothing && continue
        version = env.manifest[uuid].version
        version === nothing || version in Pkg.Types.semver_spec(bound) ||
            error("$name $version does not satisfy its compat bound $(repr(bound))")
    end
end

"""
    prepare(context, directory; instantiate=true) -> Environment

Write the analysis environment for `context` into the empty `directory`: the combined
dependencies, sources, compat bounds and effective preferences of its projects, together
with the analyzer, resolved from their existing manifests where possible. With
`instantiate`, missing packages are downloaded; otherwise resolution considers installed
versions only. Dependency build scripts never run; see also `precompile_environment`.
"""
function prepare(context::Context, directory::String; instantiate::Bool=true)
    directory = abspath(directory)
    isdir(directory) && !isempty(readdir(directory)) &&
        return Environment(:failed, directory, "preparation directory is not empty: $directory")
    # Undeclared imports are added if they resolve; failing that, those of the workspace;
    # failing that, none, so that what is declared can still be analyzed.
    workspace = filter(((_, path),) -> !isempty(path), context.imports)
    failure = ""
    for imports in unique([context.imports, workspace, Dict{String,String}()])
        environment = _prepared(Context(context.project, context.owner, context.test, context.triggers, imports),
                                directory, instantiate)
        if !ready(environment) && !isempty(imports)
            isempty(failure) && (failure = first(split(environment.message, '\n')))
            rm(directory; recursive=true, force=true)
            continue
        end
        ready(environment) && !isempty(context.imports) || return environment
        deps = keys(TOML.parsefile(joinpath(directory, "Project.toml"))["deps"])
        added = sort!([name for name in keys(imports) if name in deps])
        dropped = sort!([name for name in keys(context.imports) if !(name in added)])
        notes = String[]
        isempty(added) || push!(notes, "It adds packages imported without being declared: $(join(added, ", ")).")
        isempty(dropped) || push!(notes, "Packages imported without being declared that could not be added: " *
            join(dropped, ", ") * (isempty(failure) ? "." : " ($failure)."))
        return Environment(:ready, directory, strip(join(notes, " ") * " " * environment.message))
    end
end

function _prepared(context::Context, directory::String, instantiate::Bool)
    try
        mkpath(directory)
        envs = _context_envs(context)
        project, preferences = _scratch_project(context, envs)
        manifest = _refresh_paths!(_seed_manifest(envs), project, envs)
        deferred = _add_tool!(project, preferences, manifest)
        project_file = _write_toml(joinpath(directory, "Project.toml"), project)
        _write_toml(joinpath(directory, "LocalPreferences.toml"), preferences)
        env = Pkg.Types.EnvCache(project_file)
        # Supply the partial seed in memory: Pkg rejects an incomplete manifest on disk
        # before it can resolve the missing entries.
        env.manifest = manifest
        notes = String[]
        # Offline, Pkg resolves among the installed versions only.
        offline = Pkg.OFFLINE_MODE[]
        Pkg.offline(offline || !instantiate)
        try
            ctx = Pkg.Types.Context(; env)
            seed = deepcopy(env)
            try
                _resolve!(ctx; exact=true, download=instantiate)
            catch err
                err isa Pkg.Resolve.ResolverError || rethrow()
                ctx.env = deepcopy(seed)
                _resolve!(ctx; exact=false, download=instantiate)
                changed = sort!(["$(entry.name) $(entry.version) → $(ctx.env.manifest[uuid].version)"
                                 for (uuid, entry) in seed.manifest if haskey(ctx.env.manifest, uuid) &&
                                 entry.version !== nothing && entry.version != ctx.env.manifest[uuid].version])
                push!(notes, "The locked versions are incompatible with this context, so it was re-resolved" *
                    (isempty(changed) ? "." : ": " * join(changed, ", ") * "."))
            end
        catch err
            instantiate || err isa InterruptException ||
                error("downloads are disabled, and the installed packages do not satisfy this context: ",
                      sprint(showerror, err))
            rethrow()
        finally
            Pkg.offline(offline)
        end
        env = Pkg.Types.EnvCache(project_file)
        unavailable = _unavailable(env)
        isempty(unavailable) || error(instantiate ? unavailable : "$unavailable (downloads are disabled)")
        _check_deferred(env, deferred)
        return Environment(:ready, directory, join(notes, " "))
    catch err
        err isa InterruptException && rethrow()
        return Environment(:failed, directory, sprint(showerror, err))
    end
end

"""
Precompile the packages of a prepared environment for its workers, and return a note on
what failed, if anything. Workers load packages without package images from source.
"""
function precompile_environment(directory::String)
    try
        env = Pkg.Types.EnvCache(joinpath(directory, "Project.toml"))
        Pkg.precompile(Pkg.Types.Context(; env), Pkg.Types.PackageSpec[]; already_instantiated=true, warn_loaded=false)
        return ""
    catch err
        err isa InterruptException && rethrow()
        return "Some packages failed to precompile and load from source: " * first(split(sprint(showerror, err), '\n'))
    end
end
