function _tool_package_identity(env, entry)
    path = Pkg.Operations.source_path(env.manifest_file, entry)
    source = path === nothing ? "" : ispath(path) ? realpath(path) : abspath(path)
    return (name=something(entry.name, ""), version=entry.version === nothing ? "" : string(entry.version), source=source)
end

function _tool_matches_target(tool_env, tool_entry, target_env, target_entry)
    actual = _tool_package_identity(tool_env, tool_entry)
    expected = _tool_package_identity(target_env, target_entry)
    return actual.name == expected.name &&
        (isempty(expected.version) || actual.version == expected.version) &&
        (isempty(expected.source) || actual.source == expected.source)
end

function _tool_input_fingerprints!(fingerprints, env)
    _environment_fingerprint!(fingerprints, env.manifest_file)
    for file in Base.get_projects_workspace_to_root(env.project_file)
        _environment_fingerprint!(fingerprints, file)
        for name in Base.preferences_names
            _environment_fingerprint!(fingerprints, joinpath(dirname(file), name))
        end
    end
    return
end

function _tool_effective_preferences(env, uuid::UUID)
    preferences = Dict{String,Any}()
    for file in reverse(Base.get_projects_workspace_to_root(env.project_file))
        preferences = Base.recursive_prefs_merge(preferences, Base.collect_preferences(file, uuid))
    end
    return preferences
end

function _tool_preference_mismatches(actual, target, shared)
    return Set(uuid for uuid in shared if _tool_effective_preferences(actual, uuid) != _tool_effective_preferences(target, uuid))
end

function _tool_preferences(baseline, target, manifest)
    preferences = Dict{String,Any}()
    bindings = Dict{String,String}()
    for uuid in sort!(collect(keys(manifest)); by=string)
        env = haskey(target.manifest, uuid) ? target : baseline
        values = _tool_effective_preferences(env, uuid)
        isempty(values) && continue
        name = manifest[uuid].name
        name === nothing && error("Tool preference dependency $uuid has no name")
        haskey(bindings, name) && bindings[name] != string(uuid) &&
            error("Distinct preference UUIDs named $name cannot share one tool preference table")
        preferences[name] = values
        bindings[name] = string(uuid)
    end
    return preferences, bindings
end

function _tool_unresolved_state(actual, target, sources, preferences)
    state = Dict{String,Any}()
    for uuid in union(sources, preferences)
        state[string(uuid)] = (
            actual=_tool_package_identity(actual, actual.manifest[uuid]),
            target=_tool_package_identity(target, target.manifest[uuid]),
            actual_preferences=_tool_effective_preferences(actual, uuid),
            target_preferences=_tool_effective_preferences(target, uuid))
    end
    return state
end

function _tool_source_manifest(env, package_file::String)
    manifest = deepcopy(env.manifest)
    for entry in values(manifest)
        entry.path === nothing || (entry.path = abspath(dirname(env.manifest_file), entry.path))
        if entry.repo.source !== nothing && !Pkg.Types.isurl(entry.repo.source)
            entry.repo.source = abspath(dirname(env.manifest_file), entry.repo.source)
        end
    end
    package, entry = _environment_local_entry(package_file)
    manifest[package.uuid] = entry
    Pkg.Operations.prune_manifest(manifest, Set([package.uuid]))
    return manifest, package
end

function _tool_target_closure!(seed, target, roots, fixed, baseline, aligned, fingerprints)
    pending = collect(roots)
    visited = Set{UUID}()
    while !isempty(pending)
        uuid = popfirst!(pending)
        uuid in visited && continue
        push!(visited, uuid)
        desired = get(target.manifest, uuid, nothing)
        desired === nothing && error("Prepared target has no entry for shared dependency $uuid")
        if Pkg.Types.is_stdlib(uuid)
            existing = get(baseline.manifest, uuid, nothing)
            existing === nothing || _tool_matches_target(baseline, existing, target, desired) ||
                error("Prepared target conflicts with fixed Julia dependency $(desired.name) ($uuid)")
            seed[uuid] = deepcopy(desired)
            continue
        elseif uuid in fixed
            existing = get(baseline.manifest, uuid, nothing)
            existing !== nothing && _tool_matches_target(baseline, existing, target, desired) ||
                error("Prepared target conflicts with fixed tool dependency $(desired.name) ($uuid)")
            continue
        end
        identity = _tool_package_identity(target, desired)
        file = _environment_project_file(identity.source)
        file === nothing && error("Prepared target source for $(desired.name) ($uuid) is unavailable: $(identity.source)")
        project = Pkg.Types.read_project(file)
        project.uuid == uuid && project.name == desired.name ||
            error("Prepared target source identity does not match $(desired.name) ($uuid)")
        if desired.version !== nothing && project.version !== nothing
            desired.version == project.version || error("Prepared target source version does not match $(desired.name)")
        end
        entry = deepcopy(desired)
        entry.path = identity.source
        entry.repo = Pkg.Types.GitRepo()
        entry.tree_hash = nothing
        entry.pinned = true
        seed[uuid] = entry
        push!(aligned, uuid)
        _environment_source_inputs!(fingerprints, file, Set{String}())
        append!(pending, values(desired.deps))
    end
    return
end

"Align the worker's tool dependencies with an exact prepared target without changing that target."
function prepare_tool_environment(target::EnvironmentResult, directory::String; instantiate::Bool=true)::EnvironmentResult
    target.status === :ready || return target
    fingerprints = copy(target.fingerprints)
    try
        baseline_file = _environment_project_file(_tool_project())
        baseline_file === nothing && error("The loaded JETSweep tool environment cannot be located")
        baseline = Pkg.Types.EnvCache(baseline_file)
        target_file = _environment_project_file(target.project)
        target_file === nothing && error("The prepared target project cannot be located")
        desired = Pkg.Types.EnvCache(target_file)
        _tool_input_fingerprints!(fingerprints, baseline)
        _tool_input_fingerprints!(fingerprints, desired)
        package_file = _environment_project_file(dirname(@__DIR__))
        package_file === nothing && error("The installed JETSweep project cannot be located")
        seed, package = _tool_source_manifest(baseline, package_file)
        baseline.manifest = deepcopy(seed)
        jetls_uuid = package.deps["JETLS"]
        jetls = get(seed, jetls_uuid, nothing)
        jetls === nothing && error("JETLS is absent from the resolved tool manifest")
        fixed = Set([package.uuid, jetls_uuid])
        for (uuid, entry) in seed
            # The release and its private vendored packages retain their exact
            # source revisions. Canonical dependencies such as Revise can align
            # only when the unchanged upstream compatibility constraints allow it.
            entry.repo.source !== nothing && entry.repo.source == jetls.repo.source && push!(fixed, uuid)
        end
        shared = intersect(Set(keys(seed)), Set(keys(desired.manifest)))
        mismatches = Set(uuid for uuid in shared if !_tool_matches_target(baseline, seed[uuid], desired, desired.manifest[uuid]))
        preference_mismatches = _tool_preference_mismatches(baseline, desired, shared)
        if isempty(mismatches) && isempty(preference_mismatches)
            return EnvironmentResult(status=:ready, project=target.project, load_paths=target.load_paths,
                tool_project=dirname(baseline_file), message=target.message, fingerprints=fingerprints)
        end
        directory = abspath(directory)
        isdir(directory) && !isempty(readdir(directory)) && error("Tool preparation directory must be empty: $directory")
        mkpath(directory)
        aligned = Set{UUID}()
        initial_names = sort!(unique!([desired.manifest[uuid].name for uuid in union(mismatches, preference_mismatches)]))
        base_project = Dict{String,Any}("deps" => Dict(package.name => string(package.uuid), "JETLS" => string(jetls_uuid)),
            "sources" => Dict(package.name => Dict("path" => dirname(package_file))),
            "compat" => Dict(package.name => "=" * string(package.version), "JETLS" => "=" * string(jetls.version)))
        project_file = joinpath(directory, "Project.toml")
        first_iteration = true
        unresolved_states = Dict{String,Any}[]
        current = baseline
        iterations = 0
        while first_iteration || !isempty(mismatches) || !isempty(preference_mismatches)
            iterations += 1
            iterations <= length(desired.manifest) + 2 ||
                error("Tool alignment did not converge for the prepared dependency and preference context")
            unresolved = _tool_unresolved_state(current, desired, mismatches, preference_mismatches)
            any(previous -> previous == unresolved, unresolved_states) &&
                error("Tool alignment made no progress for unresolved dependency identities or preferences")
            push!(unresolved_states, deepcopy(unresolved))
            !isempty(mismatches) && all(uuid -> uuid in aligned, mismatches) && error("Resolver did not preserve exact target dependency identities")
            first_iteration = false
            _tool_target_closure!(seed, desired, mismatches, fixed, baseline, aligned, fingerprints)
            preferences, preference_bindings = _tool_preferences(baseline, desired, seed)
            project = deepcopy(base_project)
            isempty(preference_bindings) || (project["extras"] = preference_bindings)
            # Never add shared package names to root sources/compat: Pkg currently
            # applies those entries by name, including to different private UUIDs
            # with the same name. Explicit pinned manifest paths preserve UUIDs.
            open(io -> TOML.print(io, project; sorted=true), project_file, "w")
            preference_file = joinpath(directory, "LocalPreferences.toml")
            if isempty(preferences)
                rm(preference_file; force=true)
            else
                open(io -> TOML.print(io, preferences; sorted=true), preference_file, "w")
            end
            env = Pkg.Types.EnvCache(project_file)
            env.manifest = deepcopy(seed)
            if !instantiate
                unavailable = _environment_unavailable(env)
                isempty(unavailable) || error("Tool environment unavailable with instantiate=false: $unavailable")
            end
            ctx = Pkg.Types.Context(env=env)
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                _environment_resolve_without_builds!(ctx; download=instantiate)
            end
            resolved = ctx.env
            for uuid in fixed
                before = baseline.manifest[uuid]
                after = get(resolved.manifest, uuid, nothing)
                after !== nothing && _tool_matches_target(resolved, after, baseline, before) &&
                    after.tree_hash == before.tree_hash && after.repo == before.repo ||
                    error("Resolver changed fixed tool dependency $(before.name) ($uuid)")
            end
            shared = intersect(Set(keys(resolved.manifest)), Set(keys(desired.manifest)))
            mismatches = Set(uuid for uuid in shared if !_tool_matches_target(resolved, resolved.manifest[uuid], desired, desired.manifest[uuid]))
            preference_mismatches = _tool_preference_mismatches(resolved, desired, shared)
            if isempty(mismatches) && isempty(preference_mismatches)
                unavailable = _environment_unavailable(resolved)
                isempty(unavailable) || error("Adapted tool environment unavailable: $unavailable")
                _tool_input_fingerprints!(fingerprints, resolved)
            else
                seed = deepcopy(resolved.manifest)
                current = resolved
            end
        end
        message = join(filter(!isempty, [target.message,
            "Tool dependencies aligned with the exact target sources and preferences: " * join(initial_names, ", ") * "."]), " ")
        return EnvironmentResult(status=:ready, project=target.project, load_paths=target.load_paths,
            tool_project=directory, message=message, fingerprints=fingerprints)
    catch exception
        exception isa InterruptException && rethrow()
        return EnvironmentResult(status=:failed, project=target.project, load_paths=target.load_paths,
            message="Tool/target dependency graph is incompatible: " * sprint(showerror, exception), fingerprints=fingerprints)
    end
end
