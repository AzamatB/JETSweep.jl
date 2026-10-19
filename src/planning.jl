struct _SourceFacts
    includes::Vector{String}
    issues::Vector{String}
end

_syntax_name(value::Symbol) = String(value)
_syntax_name(value::GlobalRef) = String(value.name)
_syntax_name(value::QuoteNode) = _syntax_name(value.value)
_syntax_name(value::Expr) = value.head === :. ? _syntax_name(last(value.args)) : ""
_syntax_name(value) = ""

function _literal_path(value, file::String, bindings::Dict{Symbol,String}, packages::Dict{String,String})
    value isa String && return value
    value isa Symbol && return get(bindings, value, nothing)
    value isa Expr || return nothing
    if value.head === :macrocall
        name = _syntax_name(first(value.args))
        name == "@__DIR__" && return dirname(file)
        name == "@__FILE__" && return file
    elseif value.head === :call
        name = _syntax_name(first(value.args))
        if name == "pkgdir" && length(value.args) >= 2 && value.args[2] isa Symbol
            root = get(packages, String(value.args[2]), nothing)
            root === nothing && return nothing
            parts = [_literal_path(arg, file, bindings, packages) for arg in value.args[3:end]]
            all(part -> part isa String, parts) || return nothing
            return joinpath(root, parts...)
        end
        parts = [_literal_path(arg, file, bindings, packages) for arg in value.args[2:end]]
        all(part -> part isa String, parts) || return nothing
        name == "joinpath" && !isempty(parts) && return joinpath(parts...)
        name == "dirname" && length(parts) == 1 && return dirname(only(parts))
        name == "normpath" && !isempty(parts) && return normpath(parts...)
        # Relative abspath depends on the process working directory, which is
        # deliberately not guessed during source discovery.
        name == "abspath" && !isempty(parts) && isabspath(first(parts)) && return abspath(parts...)
        name == "*" && return join(parts)
    end
    return nothing
end

function _source_facts(file::String, packages::Dict{String,String})
    includes = String[]
    issues = String[]
    syntax = try
        Meta.parseall(read(file, String); filename=file)
    catch err
        return _SourceFacts(includes, ["$file: source parse failed: $(sprint(showerror, err))"])
    end
    function assigned_names!(names, expression)
        expression isa Expr || return
        expression.head === :(=) && first(expression.args) isa Symbol && push!(names, first(expression.args))
        foreach(child -> assigned_names!(names, child), expression.args)
    end
    function inspect(expression, bindings, line=1)
        expression isa Expr || return
        if expression.head in (:error, :incomplete)
            push!(issues, "$file:$line: source parse failed: $(join(string.(expression.args), ' '))")
            return
        elseif expression.head === :quote
            # Quoted syntax is data; a later eval remains an explicit limitation.
            return
        elseif expression.head in (:if, :try, :&&, :||)
            for child in expression.args
                child isa LineNumberNode ? (line = child.line) : inspect(child, copy(bindings), line)
            end
            # A conditional assignment is not an unconditional path binding.
            assigned = Set{Symbol}()
            assigned_names!(assigned, expression)
            foreach(name -> delete!(bindings, name), assigned)
            return
        elseif expression.head === :call && !isempty(expression.args)
            name = _syntax_name(first(expression.args))
            if name == "include"
                target = length(expression.args) in (2, 3, 4) ?
                    _literal_path(last(expression.args), file, bindings, packages) : nothing
                if target === nothing
                    push!(issues, "$file:$line: dynamic include target cannot be resolved statically")
                else
                    push!(includes, abspath(dirname(file), target))
                end
            elseif name in ("eval", "include_string")
                push!(issues, "$file:$line: $name may introduce source unavailable to static include discovery")
            end
        elseif expression.head === :(=) && length(expression.args) == 2 && first(expression.args) isa Symbol
            name = first(expression.args)
            value = _literal_path(last(expression.args), file, bindings, packages)
            if value === nothing
                delete!(bindings, name)
            else
                bindings[name] = value
            end
        end
        # Local/module bindings cannot leak into the surrounding source context.
        scoped = expression.head in (:module, :function, :let, :for, :while, :->) ||
                 (expression.head === :(=) && first(expression.args) isa Expr)
        localbindings = scoped ? copy(bindings) : bindings
        for child in expression.args
            if child isa LineNumberNode
                line = child.line
            else
                inspect(child, localbindings, line)
            end
        end
    end
    inspect(syntax, Dict{Symbol,String}())
    return _SourceFacts(sort!(unique!(includes)), sort!(unique!(issues)))
end

function _declared_package_path(directory::String, name::String, uuid::String)
    isdir(directory) || return nothing
    for filename in ("JuliaProject.toml", "Project.toml")
        project = joinpath(directory, filename)
        isfile(project) || continue
        data = try
            TOML.parsefile(project)
        catch
            return nothing
        end
        return get(data, "name", "") == name && get(data, "uuid", "") == uuid ? directory : nothing
    end
    return nothing
end

function _source_package_paths(source::SourceRecord, inventory::Inventory)
    paths = Dict{String,String}()
    owner = findfirst(project -> project.path == source.owner, inventory.projects)
    if owner !== nothing
        package = inventory.projects[owner]
        isempty(package.entry) || (paths[package.name] = package.path)
    end
    context = findfirst(project -> project.path == source.project, inventory.projects)
    context === nothing && return paths
    project = inventory.projects[context]
    project_file = findfirst(name -> isfile(joinpath(project.path, name)), ("JuliaProject.toml", "Project.toml"))
    project_file === nothing && return paths
    file = joinpath(project.path, ("JuliaProject.toml", "Project.toml")[project_file])
    data = try
        TOML.parsefile(file)
    catch
        return paths
    end
    declarations = get(data, "sources", Dict{String,Any}())
    declarations isa AbstractDict || return paths
    manifest_file = try
        Base.project_file_manifest_path(file)
    catch
        nothing
    end
    manifest = if manifest_file !== nothing && isfile(manifest_file)
        try
            TOML.parsefile(manifest_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    entries = get(manifest, "deps", manifest)
    entries isa AbstractDict || (entries = Dict{String,Any}())
    identities = merge(project.deps, project.weakdeps)
    extras = get(data, "extras", Dict{String,Any}())
    if extras isa AbstractDict
        for (name, uuid) in extras
            uuid isa String && tryparse(UUID, uuid) !== nothing && get!(identities, name, uuid)
        end
    end
    for (name, uuid) in identities
        haskey(paths, name) && continue
        directory = nothing
        if haskey(declarations, name)
            declaration = declarations[name]
            # Explicit sources override a stale manifest during preparation.
            # URL sources and malformed path declarations are not guessed.
            declaration isa AbstractDict || continue
            path = get(declaration, "path", nothing)
            path isa String || continue
            directory = abspath(project.path, path)
        elseif manifest_file !== nothing
            candidates = get(entries, name, Any[])
            candidates isa AbstractDict && (candidates = [candidates])
            candidates isa AbstractVector || continue
            matching = filter(entry -> entry isa AbstractDict && get(entry, "uuid", "") == uuid, candidates)
            length(matching) == 1 || continue
            path = get(only(matching), "path", nothing)
            path isa String || continue
            directory = abspath(dirname(manifest_file), path)
        end
        directory === nothing && continue
        verified = _declared_package_path(directory, name, uuid)
        verified === nothing || (paths[name] = verified)
    end
    return paths
end

function _reachable(entry::String, facts::Dict{String,_SourceFacts})
    seen = Set{String}()
    pending = [entry]
    while !isempty(pending)
        path = pop!(pending)
        path in seen && continue
        push!(seen, path)
        haskey(facts, path) && append!(pending, facts[path].includes)
    end
    return seen
end

function _include_chain(entry::String, parents::Dict{String,Vector{String}}, sources::Dict{String,SourceRecord},
                        issues::Vector{String})
    chain = String[]
    seen = Set([entry])
    current = entry
    while true
        candidates = get(parents, current, String[])
        # Keep inherited context in the same package (or the same unnamed
        # environment). Cross-package inclusion still appears in coverage.
        source = sources[entry]
        candidates = filter(candidates) do path
            parent = sources[path]
            isempty(source.owner) ? parent.project == source.project : parent.owner == source.owner
        end
        isempty(candidates) && break
        if length(candidates) > 1
            push!(issues, "$current: multiple containing files require an explicit setup context: $(join(candidates, ", "))")
            break
        end
        current = only(candidates)
        if current in seen
            push!(issues, "$entry: include cycle prevents a unique containing-file context")
            break
        end
        push!(seen, current)
        pushfirst!(chain, current)
    end
    return chain
end

function _test_entry(source::SourceRecord, sources::Dict{String,SourceRecord}, chain::Vector{String})
    source.kind === :test || return ""
    candidates = filter(path -> basename(path) == "runtests.jl", chain)
    isempty(candidates) || return first(candidates)
    directory = dirname(source.path)
    boundary = isempty(source.owner) ? (isempty(source.project) ? dirname(source.path) : source.project) : source.owner
    while _within(directory, boundary)
        candidate = joinpath(directory, "runtests.jl")
        candidate != source.path && haskey(sources, candidate) && return candidate
        directory == boundary && break
        directory = dirname(directory)
    end
    return ""
end

function _job_issues(paths, facts::Dict{String,_SourceFacts}, sources::Dict{String,SourceRecord})
    issues = String[]
    for path in paths
        if !haskey(facts, path)
            reason = isfile(path) ? "expected source is excluded from the inventory" : "expected source does not exist"
            push!(issues, "$path: $reason")
            continue
        end
        append!(issues, facts[path].issues)
        for included in facts[path].includes
            haskey(sources, included) && continue
            reason = isfile(included) ? "included source is excluded from the inventory" : "included source does not exist"
            push!(issues, "$path: $reason: $included")
        end
    end
    return sort!(unique!(issues))
end

function _blocking_issues(issues::Vector{String})
    return filter(issues) do issue
        occursin("source parse failed", issue) || occursin("expected source does not exist", issue) ||
            occursin("has no declared dependency UUID", issue)
    end
end

function _job_id(kind::Symbol, entry::String, root::String; extension::String="")
    identity = string(kind, '\0', _slash(relpath(entry, root)), '\0', extension)
    return string(kind, "-", bytes2hex(sha256(identity))[1:16])
end

function _config_string_vector(value, name::String)
    value isa Vector && all(item -> item isa String, value) ||
        throw(ArgumentError("$name must be an array of strings"))
    return String[value...]
end

function _configured_jobs(jobs::Vector{AnalysisJob}, inventory::Inventory, config::String)
    file = isempty(config) ? joinpath(inventory.root, ".JETSweep.toml") : abspath(config)
    !isfile(file) && isempty(config) && return jobs
    isfile(file) || throw(ArgumentError("JETSweep configuration does not exist: $file"))
    data = TOML.parsefile(file)
    unexpected = setdiff(keys(data), ["jobs"])
    isempty(unexpected) || throw(ArgumentError("unknown JETSweep configuration keys: $(join(unexpected, ", "))"))
    overrides = get(data, "jobs", Any[])
    overrides isa Vector || throw(ArgumentError("JETSweep jobs must use [[jobs]] tables"))
    base = dirname(file)
    configured = copy(jobs)
    for override in overrides
        override isa AbstractDict || throw(ArgumentError("each [[jobs]] override must be a table"))
        allowed = ["match", "project", "setup", "args", "env", "jetls_config"]
        unexpected = setdiff(keys(override), allowed)
        isempty(unexpected) || throw(ArgumentError("unknown [[jobs]] keys: $(join(unexpected, ", "))"))
        pattern = get(override, "match", nothing)
        pattern isa String || throw(ArgumentError("each [[jobs]] override requires a string match"))
        selected = findall(job -> occursin(_glob_regex(pattern), _slash(relpath(job.entry, inventory.root))), configured)
        isempty(selected) && throw(ArgumentError("configuration pattern matches no analysis jobs: $pattern"))
        for index in selected
            job = configured[index]
            context = job.context
            project = context.project
            setup = copy(context.setup)
            arguments = copy(context.arguments)
            variables = copy(context.variables)
            configuration = context.configuration
            if haskey(override, "project")
                override["project"] isa String || throw(ArgumentError("project must be a path string"))
                project = abspath(base, override["project"])
                isfile(project) && basename(project) in ("JuliaProject.toml", "Project.toml") && (project = dirname(project))
                isdir(project) || throw(ArgumentError("configured project directory does not exist: $project"))
                any(name -> isfile(joinpath(project, name)), ("JuliaProject.toml", "Project.toml")) ||
                    throw(ArgumentError("configured project has no Julia project file: $project"))
            end
            if haskey(override, "setup")
                setup = [abspath(base, path) for path in _config_string_vector(override["setup"], "setup")]
                all(isfile, setup) || throw(ArgumentError("configured setup files must exist: $(join(setup, ", "))"))
            end
            haskey(override, "args") && (arguments = _config_string_vector(override["args"], "args"))
            if haskey(override, "env")
                values = override["env"]
                values isa AbstractDict && all(value -> value isa String, Base.values(values)) ||
                    throw(ArgumentError("env must be a table of string values"))
                merge!(variables, Dict{String,String}(String(key) => value for (key, value) in values))
            end
            if haskey(override, "jetls_config")
                override["jetls_config"] isa String || throw(ArgumentError("jetls_config must be a path string"))
                configuration = abspath(base, override["jetls_config"])
                isfile(configuration) || throw(ArgumentError("configured JETLS configuration does not exist: $configuration"))
            end
            configured[index] = AnalysisJob(id=job.id, kind=job.kind, entry=job.entry,
                project=project, owner=job.owner, expected_files=job.expected_files,
                extension=job.extension, triggers=job.triggers,
                issues=isempty(setup) ? job.issues : filter(issue -> !occursin("multiple containing files require an explicit setup context", issue), job.issues),
                blocking_issues=job.blocking_issues,
                context=ContextSpec(; project, setup, arguments, variables, configuration,
                                    test_entry=context.test_entry, containing_files=context.containing_files))
        end
    end
    return configured
end

"""
    plan(inventory; config="")

Create isolated package, extension, test, and standalone-source jobs. Every source
belongs to at least one job's expected coverage, including disconnected package
sources. Include edges are inferred from syntax without executing user source.
Unresolved include/context paths are explicit job issues. An optional `.JETSweep.toml`
uses `[[jobs]]` with `match`, `project`, `setup`, `args`, `env`, and `jetls_config`.
Patterns match root-relative entry paths; configured paths resolve beside that TOML.
"""
function plan(inventory::Inventory; config::String="")::Vector{AnalysisJob}
    sources = Dict(source.path => source for source in inventory.files)
    contexts = Dict{Tuple{String,String},Dict{String,String}}()
    facts = Dict{String,_SourceFacts}()
    for source in inventory.files
        packages = get!(contexts, (source.owner, source.project)) do
            _source_package_paths(source, inventory)
        end
        facts[source.path] = _source_facts(source.path, packages)
    end
    parents = Dict{String,Vector{String}}()
    for (path, fact) in facts, included in fact.includes
        haskey(sources, included) || continue
        push!(get!(parents, included, String[]), path)
    end
    foreach(sort!, values(parents))
    jobs = AnalysisJob[]
    assigned = Set{String}()
    for project in inventory.projects
        isempty(project.entry) && continue
        reachable = _reachable(project.entry, facts)
        expected = sort!([source.path for source in inventory.files if source.owner == project.path &&
                         source.path in reachable])
        project.entry in expected || push!(expected, project.entry)
        sort!(expected)
        issues = _job_issues(expected, facts, sources)
        push!(jobs, AnalysisJob(id=_job_id(:package, project.entry, inventory.root), kind=:package,
            entry=project.entry, project=project.path, owner=project.path, expected_files=expected,
            context=ContextSpec(project=project.path), issues=issues, blocking_issues=_blocking_issues(issues)))
        union!(assigned, expected)
        for name in sort!(collect(keys(project.extensions)))
            flat = joinpath(project.path, "ext", "$name.jl")
            nested = joinpath(project.path, "ext", name, "$name.jl")
            entry = isfile(flat) ? flat : nested
            reachable = _reachable(entry, facts)
            expected = sort!([source.path for source in inventory.files if source.owner == project.path &&
                source.path in reachable])
            entry in expected || push!(expected, entry)
            sort!(expected)
            issues = _job_issues(expected, facts, sources)
            triggers = Dict{String,String}()
            for trigger in project.extensions[name]
                uuid = get(project.weakdeps, trigger, get(project.deps, trigger, ""))
                isempty(uuid) && push!(issues, "$entry: extension trigger $trigger has no declared dependency UUID")
                triggers[trigger] = uuid
            end
            push!(jobs, AnalysisJob(id=_job_id(:extension, entry, inventory.root; extension=name), kind=:extension,
                entry=entry, project=project.path, owner=project.path, expected_files=expected,
                extension=name, triggers=triggers, context=ContextSpec(project=project.path),
                issues=sort!(unique!(issues)), blocking_issues=_blocking_issues(issues)))
            union!(assigned, expected)
        end
    end
    for source in inventory.files
        source.path in assigned && continue
        issues = _job_issues([source.path], facts, sources)
        chain = _include_chain(source.path, parents, sources, issues)
        test_entry = _test_entry(source, sources, chain)
        containing = filter(path -> path != test_entry, chain)
        context_paths = isempty(test_entry) ? containing : [test_entry; containing]
        # The backend retains declarations before the target's include, not
        # arbitrary execution from the complete driver. It reports the actual
        # header omissions; unrelated driver calls must not taint leaf jobs.
        append!(issues, filter(issue -> occursin("source parse failed", issue),
                               _job_issues(context_paths, facts, sources)))
        kind = source.kind === :test ? :test :
               source.kind in (:package_source, :extension) ? :source : :script
        if kind === :source
            push!(issues, "$(source.path): source is not statically reachable from its package or extension entry; analysis uses the parent package exports, and its hypothetical internal inclusion context is unknown")
        end
        push!(jobs, AnalysisJob(id=_job_id(kind, source.path, inventory.root), kind=kind,
            entry=source.path, project=source.project, owner=source.owner, expected_files=[source.path],
            context=ContextSpec(project=source.project, test_entry=test_entry, containing_files=containing),
            issues=sort!(unique!(issues)), blocking_issues=_blocking_issues(issues)))
    end
    sort!(jobs; by=job -> (job.entry, String(job.kind), job.extension))
    return _configured_jobs(jobs, inventory, config)
end
