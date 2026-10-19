module JETSweepBackend

# This module is deliberately absent from src/JETSweep.jl. Only disposable
# analysis workers load JETLS and its compiler/runtime dependencies.
using JETSweep
using JETLS
using TOML
using SHA
using Logging

const SUPPORTED_JETLS = "2026.10.14"
const LS = Base.require(JETLS, :JETLSCore)
const BLOCKING_CODES = Set(("toplevel/error", "toplevel/missing-concretization",
    "toplevel/concretization-timeout", "toplevel/unsupported-feature",
    "toplevel/analysis-skipped", "toplevel/analysis-stopped"))

struct UnsupportedBackend <: Exception
    message::String
end
Base.showerror(io::IO, e::UnsupportedBackend) = print(io, e.message)

struct WorkerJob
    id::String
    kind::Symbol
    entry::String
    project::String
    owner::String
    expected::Vector{String}
    extension::String
    triggers::Dict{String,String}
    setup::Vector{String}
    arguments::Vector{String}
    variables::Dict{String,String}
    test_entry::String
    containing_files::Vector{String}
    issues::Vector{String}
    blocking_issues::Vector{String}
end

struct WorkerSpec
    root::String
    config::String
    environment::String
    load_paths::Vector{String}
    job::WorkerJob
end

strings(xs) = String[String(x) for x in xs]
stringdict(d) = Dict{String,String}(String(k) => String(v) for (k,v) in d)
function projectfile(path::String)
    isdir(path) || return path
    file = JETSweep.Pkg.Types.projectfile_path(path;strict=true)
    file === nothing && error("No Julia project metadata exists at $path")
    return file
end
canonical(path::String) = ispath(path) ? realpath(path) : abspath(path)
digest(path::String) = isfile(path) ? bytes2hex(sha256(read(path))) : "missing"
owner_project(job::WorkerJob) = !isempty(job.owner) && ispath(job.owner) ? projectfile(job.owner) : projectfile(job.project)

function module_source_root(mod::Module)
    source = pathof(mod)
    source === nothing && return nothing
    id = Base.PkgId(mod)
    directory = dirname(abspath(source))
    while true
        project = JETSweep.Pkg.Types.projectfile_path(directory;strict=true)
        if project !== nothing
            data = TOML.parsefile(project)
            if get(data,"name","") == id.name && get(data,"uuid","") == string(id.uuid)
                entry = get(data,"path",get(data,"entryfile",joinpath("src",id.name*".jl")))
                entry isa String || error("Invalid package entry metadata in $project")
                canonical(abspath(directory,entry)) == canonical(source) && return canonical(directory)
            end
        end
        parent = dirname(directory)
        parent == directory && break
        directory = parent
    end
    # Extension UUIDs differ from their parent's project UUID, while their source
    # layout is prescribed by Julia. Base handles those standard extension paths.
    return pkgdir(mod)
end

function module_version(mod::Module, root::String)
    version = lock(Base.require_lock) do
        origin = get(Base.pkgorigins,Base.PkgId(mod),nothing)
        origin === nothing ? nothing : origin.version
    end
    version === nothing || return string(version)
    project = JETSweep.Pkg.Types.projectfile_path(root;strict=true)
    project === nothing && return ""
    declared = String(get(TOML.parsefile(project),"version",""))
    return isempty(declared) ? "" : string(VersionNumber(declared))
end

function read_spec(path::String)
    data = TOML.parsefile(path)
    get(data, "schema_version", 0) == 1 || error("Unsupported worker job schema")
    job = data["job"]
    context = get(job, "context", Dict{String,Any}())
    entry = abspath(job["entry"])
    worker_job = WorkerJob(String(job["id"]), Symbol(job["kind"]), entry,
        String(job["project"]), String(get(job,"owner","")),
        unique!(vcat([entry], strings(get(job,"expected_files",String[])))),
        String(get(job,"extension","")), stringdict(get(job,"triggers",Dict())),
        strings(get(context,"setup",String[])), strings(get(context,"arguments",String[])),
        stringdict(get(context,"variables",Dict())), String(get(context,"test_entry","")),
        strings(get(context,"containing_files",String[])), strings(get(job,"issues",String[])),
        strings(get(job,"blocking_issues",String[])))
    return WorkerSpec(abspath(data["root"]), abspath(data["config_directory"]),
        projectfile(abspath(data["environment_project"])), strings(data["load_paths"]), worker_job)
end

struct AuditLogger{L<:AbstractLogger} <: AbstractLogger
    delegate::L
    errors::Vector{String}
    lock::ReentrantLock
end
Logging.min_enabled_level(l::AuditLogger) = min(Logging.Error, Logging.min_enabled_level(l.delegate))
Logging.shouldlog(l::AuditLogger, level, args...) = level >= Logging.Error || Logging.shouldlog(l.delegate, level, args...)
Logging.catch_exceptions(::AuditLogger) = false
function Logging.handle_message(l::AuditLogger, level, message, args...; kwargs...)
    if level >= Logging.Error || (level >= Logging.Warn &&
            (occursin("Couldn't find a single matching method",string(message)) ||
             occursin("Missing CodeInstance for method analysis",string(message))))
        lock(l.lock) do
            push!(l.errors, string(message, " ", kwargs))
        end
    end
    Logging.handle_message(l.delegate, level, message, args...; kwargs...)
end

function validate_julia_version(version::VersionNumber=VERSION)
    version >= v"1.13" || throw(UnsupportedBackend("JETSweep requires Julia 1.13 or later; found $version"))
    for backend in (JETLS,LS)
        data = TOML.parsefile(projectfile(something(module_source_root(backend))))
        compatibility = get(get(data,"compat",Dict()),"julia",nothing)
        compatibility isa String || throw(UnsupportedBackend("Missing Julia compatibility metadata for $(nameof(backend))"))
        version in JETSweep.Pkg.Types.semver_spec(compatibility) ||
            throw(UnsupportedBackend("Julia $version is outside pinned $(nameof(backend)) compatibility $compatibility"))
    end
    return nothing
end

function validate_backend()
    validate_julia_version()
    Base.pkgversion(JETLS) == VersionNumber(SUPPORTED_JETLS) ||
        throw(UnsupportedBackend("Expected JETLS $SUPPORTED_JETLS, found $(JETLS.JETLS_VERSION)"))
    for name in (:start_cli_server, :start_signature_analysis_workers!, :start_analysis_worker!,
        :schedule_analysis!, :get_analysis_info, :AnalysisResult, :NewAnalysisEntry,
        :ScriptInEnvAnalysisEntry, :collect_workspace_uris, :get_full_diagnostics,
        :run_per_file_diagnostics!, :cleanup_cli_tasks, :Revise, :FULL_ANALYSIS_CONTEXT)
        isdefined(LS, name) || throw(UnsupportedBackend("Pinned JETLS API missing $name"))
    end
    LS.Revise === nothing && throw(UnsupportedBackend("Pinned JETLS requires its Revise backend"))
    LS.JETLS_VERSION[] = JETLS.JETLS_VERSION
    LS.JETLS_MODULE[] = JETLS
    return nothing
end

function configure_process(spec::WorkerSpec)
    Base.set_active_project(spec.environment)
    empty!(LOAD_PATH)
    append!(LOAD_PATH, spec.load_paths)
    # JETLS is already bootstrapped. Its environment must not make undeclared
    # packages importable from the analyzed script's top-level module.
    pushfirst!(LOAD_PATH, dirname(spec.environment))
    push!(LOAD_PATH, "@stdlib")
    unique!(LOAD_PATH)
    empty!(ARGS)
    append!(ARGS, spec.job.arguments)
    merge!(ENV, spec.job.variables)
end

struct DependencyIdentity
    uuid::Base.UUID
    name::String
    version::String
    source::String
    tree_hash::String
end

function expected_dependencies(project::String)
    env = JETSweep.Pkg.Types.EnvCache(project)
    identities = Dict{Base.UUID,DependencyIdentity}()
    # Inspect every manifest UUID, including entries that Pkg.dependencies may
    # omit because they are not reachable from this Project's current deps.
    for (uuid, entry) in env.manifest
        source = JETSweep.Pkg.Operations.source_path(env.manifest_file,entry)
        source === nothing && error("Manifest source identity is unresolved for $(entry.name) ($uuid)")
        version = entry.version === nothing ? "" : string(entry.version)
        if entry.version == v"0.0.0"
            metadata = JETSweep.Pkg.Types.projectfile_path(source;strict=true)
            if metadata !== nothing
                data = TOML.parsefile(metadata)
                if !haskey(data,"version") && get(data,"name","") == entry.name && get(data,"uuid","") == string(uuid)
                    # Pkg synthesizes 0.0.0 for a valid unversioned path package.
                    version = ""
                end
            end
        end
        identities[uuid] = DependencyIdentity(uuid,entry.name,
            version,canonical(source),
            entry.tree_hash === nothing ? "" : string(entry.tree_hash))
    end
    return identities
end

loaded_modules_snapshot() = lock(Base.require_lock) do
    collect(Base.loaded_modules)
end

function loaded_preference_snapshot(expected::Dict{Base.UUID,DependencyIdentity})
    result = Dict{Base.UUID,Dict{String,Any}}()
    for (id, _) in loaded_modules_snapshot()
        id.uuid === nothing && continue
        haskey(expected,id.uuid) || continue
        result[id.uuid] = deepcopy(Base.get_preferences(id.uuid))
    end
    return result
end

function target_preference_snapshot(expected::Dict{Base.UUID,DependencyIdentity})
    return Dict(uuid=>deepcopy(Base.get_preferences(uuid)) for uuid in keys(expected))
end

function preference_verification(expected::Dict{Base.UUID,DependencyIdentity}, loaded_preferences,
        target_preferences)
    rows = Dict{String,Any}[]
    conflicts = Dict{String,Any}[]
    for (id, _) in loaded_modules_snapshot()
        id.uuid === nothing && continue
        haskey(expected,id.uuid) || continue
        # Modules absent at bootstrap are imported in the selected target context.
        actual = get(loaded_preferences,id.uuid,target_preferences[id.uuid])
        current = deepcopy(Base.get_preferences(id.uuid))
        matches = actual == target_preferences[id.uuid] == current
        row = Dict{String,Any}("uuid"=>string(id.uuid),"name"=>id.name,
            "loaded_preferences"=>actual,"target_preferences"=>target_preferences[id.uuid],
            "current_preferences"=>current,"loaded_at_bootstrap"=>haskey(loaded_preferences,id.uuid),
            "matches"=>matches)
        push!(rows,row)
        matches || push!(conflicts,row)
    end
    sort!(rows;by=row -> (row["name"],row["uuid"]))
    sort!(conflicts;by=row -> (row["name"],row["uuid"]))
    return rows, conflicts
end

function dependency_verification(expected::Dict{Base.UUID,DependencyIdentity})
    rows = Dict{String,Any}[]
    conflicts = Dict{String,Any}[]
    for (id, mod) in loaded_modules_snapshot()
        id.uuid === nothing && continue
        identity = get(expected,id.uuid,nothing)
        identity === nothing && continue
        actual_source = module_source_root(mod)
        actual_source = actual_source === nothing ? "" : canonical(actual_source)
        actual_version = isempty(actual_source) ? "" : module_version(mod,actual_source)
        same_source = isempty(identity.source) || identity.source == actual_source
        same_version = isempty(identity.version) || identity.version == actual_version
        matches = identity.name == id.name && same_source && same_version
        row = Dict{String,Any}("uuid"=>string(id.uuid),"name"=>identity.name,
            "expected_version"=>identity.version,"actual_version"=>actual_version,
            "expected_source"=>identity.source,"actual_source"=>actual_source,
            "expected_tree_hash"=>identity.tree_hash,"matches"=>matches)
        push!(rows,row)
        matches || push!(conflicts,row)
    end
    sort!(rows;by=row -> (row["name"],row["uuid"]))
    sort!(conflicts;by=row -> (row["name"],row["uuid"]))
    return rows, conflicts
end

function module_identity(mod::Module)
    id = Base.PkgId(mod)
    source = something(pathof(mod), "")
    return Dict{String,Any}("name"=>id.name, "uuid"=>string(id.uuid),
        "module"=>string(mod), "source"=>source,
        "source_sha256"=>isempty(source) ? "" : digest(source))
end

function bind_loaded_module(mod::Module)
    root = Base.__toplevel__
    name = nameof(mod)
    if Base.invokelatest(isdefined,root,name)
        Base.invokelatest(getglobal,root,name) === mod || error("Conflicting loaded module root binding: $name")
    else
        Core.eval(root,Expr(:const,Expr(:(=),name,QuoteNode(mod))))
    end
    return nothing
end

function register_observed_entry!(mod::Module, entry::String)
    data = LS.Revise.getpkgdata(Base.PkgId(mod))
    data === nothing && (data = LS.Revise.watch_package(Base.PkgId(mod)))
    data === nothing && error("Revise cannot track the requested module")
    covered = Set(canonical(joinpath(LS.Revise.basedir(data),file)) for file in LS.Revise.srcfiles(data))
    canonical(entry) in covered && return String[]
    # The pinned Revise's source-load callback recognizes loader-root files by a
    # conventional basename. Use its actual include observations for custom
    # entryfiles; this registers unchanged, already-loaded source without eval.
    observations = lock(LS.Revise.revise_lock) do
        [(context,identity,file) for (context,file) in LS.Revise.included_files if canonical(file) == canonical(entry)]
    end
    isempty(observations) && error("No observed include establishes the original package entry $entry")
    LS.Revise.maybe_add_includes_to_pkgdata!(data,"",observations;eval_now=false)
    return [entry]
end

function load_target(job::WorkerJob)
    parent_project = owner_project(job)
    data = TOML.parsefile(parent_project)
    name = String(data["name"])
    isempty(job.owner) || ispath(job.owner) || name == job.owner || error("Project owner identity mismatch")
    id = Base.PkgId(Base.UUID(data["uuid"]), name)
    parent = Base.require(id)
    Base.PkgId(parent) == id || error("Loaded wrong parent UUID")
    actual_root = module_source_root(parent)
    actual_root !== nothing && canonical(actual_root) == canonical(dirname(parent_project)) ||
        error("Loaded parent from a different checkout: $actual_root")
    # Revise's range resolver must resolve the outer `module Name` block to the
    # exact loaded package. Without this binding a single-file package can be
    # attributed to Base.__toplevel__, suppressing its inference diagnostics.
    bind_loaded_module(parent)
    job.kind === :extension || return parent, parent, Dict{String,Any}[]
    triggers = Dict{String,Any}[]
    isempty(job.triggers) && error("Extension has no resolved trigger identities")
    for (trigger, uuid) in sort!(collect(job.triggers); by=first)
        mod = Base.require(Base.PkgId(Base.UUID(uuid), trigger))
        Base.PkgId(mod).uuid == Base.UUID(uuid) || error("Loaded wrong trigger UUID")
        push!(triggers, module_identity(mod))
    end
    ext = Base.get_extension(parent, Symbol(job.extension))
    ext isa Module || error("Extension $(job.extension) did not load")
    canonical(something(pathof(ext), "")) == canonical(job.entry) ||
        error("Loaded extension source does not match its requested entry")
    bind_loaded_module(ext)
    return parent, ext, triggers
end

macro_name(x::Symbol) = String(x)
macro_name(x::QuoteNode) = macro_name(x.value)
macro_name(x::Expr) = x.head === :. ? macro_name(last(x.args)) : ""
macro_name(x) = ""

function declaration(ex)
    ex isa LineNumberNode && return true
    ex isa Expr || return false
    ex.head in (:using, :import, :export, :public, :function, :struct, :abstract,
        :primitive, :macro, :const) && return true
    if ex.head === :(=)
        lhs = first(ex.args)
        return lhs isa Expr && (lhs.head === :call || lhs.head === :where ||
            (lhs.head === :(::) && first(lhs.args) isa Expr && first(lhs.args).head === :call))
    elseif ex.head === :macrocall
        # Keep decorated declarations, including @doc, @inline, and @kwdef.
        return any(declaration, ex.args[3:end]) && macro_name(first(ex.args)) != "@eval"
    end
    return false
end

function literal_path(ex, source::String, bindings::Dict{Symbol,String}=Dict{Symbol,String}())
    ex isa String && return ex
    ex isa Symbol && return get(bindings,ex,nothing)
    ex isa Expr || return nothing
    if ex.head === :macrocall
        name = macro_name(first(ex.args))
        name == "@__DIR__" && return dirname(source)
        name == "@__FILE__" && return source
    elseif ex.head === :call && JETSweep._syntax_name(first(ex.args)) in ("joinpath", "normpath", "abspath", "dirname", "*")
        values = String[]
        for item in ex.args[2:end]
            value = literal_path(item, source, bindings)
            value === nothing && return nothing
            push!(values, value)
        end
        op = JETSweep._syntax_name(first(ex.args))
        return op == "joinpath" ? joinpath(values...) : op == "normpath" ? normpath(values...) :
            op == "dirname" && length(values) == 1 ? dirname(only(values)) :
            op == "abspath" && !isempty(values) && isabspath(first(values)) ? abspath(values...) :
            op == "*" ? join(values) : nothing
    end
    return nothing
end

function included_path(ex, source::String, bindings::Dict{Symbol,String}=Dict{Symbol,String}())
    ex isa Expr && ex.head === :call || return nothing
    string(first(ex.args)) in ("include", "Base.include") || return nothing
    length(ex.args) == 2 || return nothing
    value = literal_path(last(ex.args), source, bindings)
    value === nothing && return nothing
    return canonical(joinpath(dirname(source), value))
end

function relocate_context(ex, source::String)
    ex isa Expr || return ex
    if ex.head === :macrocall
        name = macro_name(first(ex.args))
        name == "@__DIR__" && return dirname(source)
        name == "@__FILE__" && return source
    end
    return Expr(ex.head, (relocate_context(x,source) for x in ex.args)...)
end

struct ContextFragment
    source::String
    line::Int
    expression::Expr
end
struct ContextOmission
    source::String
    line::Int
    kind::String
    reason::String
end

function context_nodes!(nodes::Vector{Union{Expr,LineNumberNode}}, expression)
    if expression isa Expr && expression.head in (:toplevel,:block)
        for child in expression.args
            context_nodes!(nodes,child)
        end
    elseif expression isa Union{Expr,LineNumberNode}
        push!(nodes,expression)
    end
    return nodes
end

function collect_context!(fragments::Vector{ContextFragment}, omissions::Vector{ContextOmission},
        sources::Vector{String}, source::String, target::String, seen::Set{String})
    source = canonical(source)
    source in seen && return
    source == canonical(target) && return
    push!(seen, source)
    push!(sources, source)
    tree = Meta.parseall(read(source, String); filename=source)
    line = 1
    bindings = Dict{Symbol,String}()
    for ex in context_nodes!(Union{Expr,LineNumberNode}[],tree)
        if ex isa LineNumberNode
            line = Int(ex.line)
            continue
        end
        ex.head in (:error,:incomplete) && error("Context source parse failed: $source:$line")
        assignment = ex isa Expr && ex.head === :const ? only(ex.args) : ex
        path_assignment = false
        if assignment isa Expr && assignment.head === :(=) && first(assignment.args) isa Symbol
            name = first(assignment.args)
            value = literal_path(last(assignment.args),source,bindings)
            if value === nothing
                delete!(bindings,name)
            else
                bindings[name] = value
                path_assignment = true
            end
        end
        path = included_path(ex, source, bindings)
        # A containing file supplies the context established before this include.
        path == canonical(target) && break
        if path !== nothing
            if isfile(path)
                collect_context!(fragments, omissions, sources, path, target, seen)
            else
                push!(omissions, ContextOmission(source,line,"include","Included context file is missing: $path"))
            end
        elseif declaration(ex) || path_assignment
            push!(fragments, ContextFragment(source,line,relocate_context(ex,source)))
        elseif ex isa Expr
            push!(omissions, ContextOmission(source,line,string(ex.head),
                "Only top-level declarations and literal include ancestry are reconstructed; this expression is omitted"))
        end
    end
end

function prepare_entry(spec::WorkerSpec, directory::String)
    job = spec.job
    if job.kind in (:package,:extension)
        return job.entry, String[], ContextOmission[], Dict{String,Any}[]
    end
    fragments = ContextFragment[]
    omissions = ContextOmission[]
    sources = String[]
    parents = unique!(vcat(isempty(job.test_entry) ? String[] : [job.test_entry], job.containing_files))
    filter!(p -> canonical(p) != canonical(job.entry), parents)
    seen = Set{String}()
    for (index, source) in enumerate(parents)
        target = index < length(parents) ? parents[index+1] : job.entry
        collect_context!(fragments, omissions, sources, source, target, seen)
    end
    wrapper = joinpath(directory, "context-entry.jl")
    spans = Dict{String,Any}[]
    open(wrapper,"w") do io
        println(io, "# Generated declaration context. Original analysis target is included unchanged.")
        # JET's virtual module constructor supplies Core.Main and does not copy
        # an actual context's Main alias. Establish this alias in the analyzed
        # virtual module itself before including any unchanged user source.
        println(io, "const Main = @__MODULE__")
        if job.kind === :source
            owner_name = String(TOML.parsefile(owner_project(job))["name"])
            Base.show_unquoted(io,Expr(:using,Expr(:.,Symbol(owner_name))))
            println(io)
        end
        for fragment in fragments
            println(io, "# Context: ", fragment.source, ":", fragment.line)
            Base.show_unquoted(io, fragment.expression)
            println(io)
            push!(spans, Dict("source"=>fragment.source,"line"=>fragment.line,
                "kind"=>string(fragment.expression.head)))
        end
        for setup in job.setup
            println(io, "include(", repr(abspath(setup)), ")")
        end
        println(io, "include(", repr(job.entry), ")")
    end
    return wrapper, sources, omissions, spans
end

function signatures(info)
    result = Dict{String,Any}[]
    if info.entry isa LS.NewAnalysisEntry
        data = LS.Revise.getpkgdata(info.entry.pkgid)
        data === nothing && error("Revise method inventory is unavailable")
        basedir = LS.Revise.basedir(data)
        for (file, fi) in zip(LS.Revise.srcfiles(data), data.fileinfos)
            for (mod, expressions) in fi.mod_exs_infos, (_, infos) in expressions
                infos === nothing && continue
                for item in infos
                    item isa LS.Revise.SigInfo || continue
                    cached = LS.Revise.get_extended_data(item,:JETLS)
                    analyzed = cached !== nothing && cached.data isa LS.SigAnalysisResult
                    push!(result, Dict("signature"=>string(item.sig), "file"=>joinpath(basedir,file),
                        "module"=>string(mod), "basis"=>"Revise signature analysis queue",
                        "analysis_verified"=>analyzed,
                        "analyzed_signature"=>analyzed ? string(cached.data.codeinst.def.specTypes) : ""))
                end
            end
        end
    else
        covered = Set(canonical(String(LS.uri2filepath(uri))) for uri in keys(info.analyzed_file_infos)
            if LS.uri2filepath(uri) !== nothing)
        for item in LS.JET.get_inf_cache(info.analyzer)
            method = item.linfo.def
            method isa Method || continue
            file = String(method.file)
            canonical(file) in covered || continue
            push!(result,Dict("signature"=>string(item.linfo.specTypes),"file"=>file,
                "module"=>string(method.module),"basis"=>"Retained JET inference cache",
                "analysis_verified"=>true,"analyzed_signature"=>string(item.linfo.specTypes)))
        end
    end
    unique!(result)
    return result
end

function diagnostic_rows(diagnostics)
    rows = Dict{String,Any}[]
    for (uri, items) in diagnostics, item in items
        file = something(LS.uri2filepath(uri), string(uri))
        related = Dict{String,Any}[]
        if item.relatedInformation !== nothing
            for information in item.relatedInformation
                location = information.location
                push!(related,Dict("uri"=>string(location.uri),
                    "file"=>something(LS.uri2filepath(location.uri),string(location.uri)),
                    "line"=>location.range.start.line+1,"column"=>location.range.start.character+1,
                    "end_line"=>location.range.var"end".line+1,
                    "end_column"=>location.range.var"end".character+1,"message"=>information.message))
            end
        end
        push!(rows, Dict("file"=>file,"uri"=>string(uri),"line"=>item.range.start.line+1,
            "column"=>item.range.start.character+1,"end_line"=>item.range.var"end".line+1,
            "end_column"=>item.range.var"end".character+1,"code"=>string(item.code),
            "severity"=>Int(something(item.severity,LS.DiagnosticSeverity.Error)),
            "message"=>LS.get_raw_message(item),"backend"=>"JETLS","related_information"=>related))
    end
    sort!(rows; by=row -> (row["file"],row["line"],row["column"],row["code"],row["message"]))
    unique!(rows)
    return rows
end

function loaded_extensions()
    rows = Dict{String,Any}[]
    for (id, parent) in loaded_modules_snapshot()
        source = pathof(parent)
        source === nothing && continue
        root = module_source_root(parent)
        root === nothing && continue
        project = JETSweep.Pkg.Types.projectfile_path(root;strict=true)
        project === nothing && continue
        data = TOML.parsefile(project)
        # Extension modules share their parent's project directory; avoid treating
        # an extension as a second parent of its own siblings.
        get(data,"name","") == id.name || continue
        for (name, trigger_names) in get(data,"extensions",Dict())
            ext = Base.get_extension(parent,Symbol(name))
            ext isa Module || continue
            trigger_names = trigger_names isa String ? [trigger_names] : trigger_names
            triggers = Dict{String,Any}[]
            dependencies = merge(get(data,"deps",Dict()),get(data,"weakdeps",Dict()))
            for trigger in trigger_names
                uuid = get(dependencies,trigger,"")
                trigger_id = isempty(uuid) ? nothing : Base.PkgId(Base.UUID(uuid),trigger)
                mod = trigger_id === nothing ? nothing : get(Base.loaded_modules,trigger_id,nothing)
                push!(triggers, mod isa Module ? module_identity(mod) :
                    Dict{String,Any}("name"=>trigger,"uuid"=>uuid,"source"=>"","loaded"=>false))
            end
            push!(rows,Dict("parent"=>module_identity(parent),"extension"=>module_identity(ext),"triggers"=>triggers))
        end
    end
    sort!(rows; by=row -> (row["parent"]["name"],row["extension"]["name"]))
    return rows
end

function analyze(spec::WorkerSpec, output::String, startup_errors::Vector{String}=String[])
    job = spec.job
    result = Dict{String,Any}("schema_version"=>1,"job_id"=>job.id,"kind"=>string(job.kind),
        "original_file"=>job.entry,"status"=>"analysis_incomplete","full_analysis_complete"=>false,
        "julia_version"=>string(VERSION),"jetls_version"=>string(JETLS.JETLS_VERSION),
        "jetls_source"=>pkgdir(JETLS),"jetls_core_source"=>pkgdir(LS),
        "jetls_dev_mode"=>LS.JETLS_DEV_MODE,
        "backend_configuration"=>Dict("JETLS_DEV_MODE"=>true,
            "overlay"=>joinpath(dirname(output),"backend-preferences")),
        "jet_version"=>string(Base.pkgversion(LS.JET)),"expected_files"=>job.expected,
        "environment"=>spec.environment,"arguments"=>job.arguments,"context_issues"=>job.issues,
        "blocking_issues"=>job.blocking_issues,
        "analyzed_files"=>String[],"diagnostics"=>Dict{String,Any}[],
        "limitations"=>[
            "JETLS full inference and live lowering diagnostics cover the recorded analysis contexts, not all Julia inputs or runtime paths.",
            "JETLS does not provide exhaustive optimization/type-stability or GPU-device analysis; no concrete workload campaign is implied.",
            "Trusted package loading, macro expansion, and JETLS concretization may execute code. Ordinary script bodies are abstractly interpreted.",
            "Automatic test context retains declarations and literal includes before the target; omitted control flow and fixture construction may require explicit setup files."])
    logger = AuditLogger(current_logger(),copy(startup_errors),ReentrantLock())
    environment_manifest = Base.project_file_manifest_path(spec.environment)
    inputs = unique!(vcat(job.expected,job.setup,job.containing_files,
        isempty(job.test_entry) ? String[] : [job.test_entry],
        isempty(job.project) && isempty(job.owner) ? String[] : [owner_project(job)],
        environment_manifest === nothing ? String[] : [environment_manifest],
        [spec.environment,joinpath(spec.config,".JETLSConfig.toml"),@__FILE__,
            joinpath(dirname(spec.environment),"LocalPreferences.toml"),
            joinpath(dirname(@__DIR__),"scripts","analyze.jl"),
            joinpath(dirname(output),"backend-preferences","Project.toml"),
            joinpath(dirname(output),"backend-preferences","Manifest.toml")]))
    before = Dict(file=>digest(file) for file in inputs)
    server = nothing
    dependencies = Dict{Base.UUID,DependencyIdentity}()
    loaded_preferences = Dict{Base.UUID,Dict{String,Any}}()
    target_preferences = Dict{Base.UUID,Dict{String,Any}}()
    try
        validate_backend()
        dependencies = expected_dependencies(spec.environment)
        loaded_preferences = loaded_preference_snapshot(dependencies)
        configure_process(spec)
        result["active_project"] = something(Base.active_project(),"")
        target_preferences = target_preference_snapshot(dependencies)
        preference_checks, preference_conflicts = preference_verification(dependencies,loaded_preferences,target_preferences)
        result["preference_identity_checks"] = preference_checks
        result["preference_identity_conflicts"] = preference_conflicts
        isempty(preference_conflicts) || error("Target effective preferences conflict with modules already loaded by the analysis tooling")
        # Neither bare names nor Main.foo in user scripts may resolve worker
        # imports or bootstrap helpers. The interpreter virtualizes this fresh
        # context; explicit setup and reconstructed declarations enter it too.
        analysis_context = Module(gensym(:JETSweepAnalysis))
        Core.eval(analysis_context,Expr(:const,Expr(:(=),:Main,QuoteNode(analysis_context))))
        LS.FULL_ANALYSIS_CONTEXT[] = analysis_context
        result["script_context_strategy"] = "fresh_module_with_virtual_main_prelude"
        result["script_context_basis"] = "Fresh module context, with const Main = @__MODULE__ analyzed before unchanged source; setup and reconstructed declarations share that abstract context"
        result["effective_load_paths"] = copy(LOAD_PATH)
        result["working_directory"] = pwd()
        result["dependency_identity_scope"] = "Every loaded package whose UUID occurs in the prepared target manifest, checked before and after analysis"
        result["target_manifest_dependency_count"] = length(dependencies)
        checks, conflicts = dependency_verification(dependencies)
        result["dependency_identity_checks"] = checks
        result["dependency_identity_conflicts"] = conflicts
        isempty(conflicts) || error("Target dependency identities conflict with modules already loaded by the analysis tooling")
        mkpath(dirname(output))
        entryfile, context_sources, omissions, fragments = prepare_entry(spec,dirname(output))
        for file in context_sources
            before[file] = digest(file)
        end
        result["entry_file"] = entryfile
        result["entry_source_sha256"] = digest(entryfile)
        result["context_sources"] = context_sources
        result["context_declarations"] = fragments
        result["context_omissions"] = [Dict("source"=>x.source,"line"=>x.line,"kind"=>x.kind,"reason"=>x.reason) for x in omissions]
        result["context_mode"] = job.kind in (:package,:extension) ? "loaded_module" :
            isempty(context_sources) ? "isolated_script" : "declaration_header"
        if job.kind === :source
            result["context_mode"] = "disconnected_package_source"
            result["original_inclusion_context_reconstructed"] = false
            result["context_basis"] = "Original source is abstractly analyzed after importing its exact owning package; this is not a loaded parent-method claim"
            push!(result["limitations"],"Disconnected source uses the owning package's exported bindings. Its original internal inclusion context is unknown; unresolved private bindings can produce context-dependent diagnostics rather than proven production defects.")
        end
        local target_module = nothing
        if job.kind in (:package,:extension)
            parent, target_module, triggers = with_logger(logger) do
                for setup in job.setup
                    Base.include(analysis_context,setup)
                end
                load_target(job)
            end
            result["parent_identity"] = module_identity(parent)
            result["target_identity"] = module_identity(target_module)
            result["requested_triggers"] = triggers
            result["module_context_alias"] = true
            result["module_context_aliases"] = unique!(["Base.__toplevel__." * String(nameof(mod)) for mod in (parent,target_module)])
            result["observed_entry_registrations"] = with_logger(logger) do
                register_observed_entry!(target_module,job.entry)
            end
        elseif job.kind === :source
            parent, _, _ = with_logger(logger) do
                load_target(job)
            end
            result["parent_identity"] = module_identity(parent)
            result["module_context_alias"] = true
            result["module_context_aliases"] = ["Base.__toplevel__." * String(nameof(parent))]
        end
        checks, conflicts = dependency_verification(dependencies)
        result["dependency_identity_checks"] = checks
        result["dependency_identity_conflicts"] = conflicts
        isempty(conflicts) || error("Loaded package dependencies do not match the prepared target manifest")
        server = with_logger(logger) do
            LS.start_cli_server(spec.config)
        end
        server.state.root_path = spec.root
        server.state.workspaceFolders = [LS.filepath2uri(spec.root)]
        with_logger(logger) do
            LS.start_signature_analysis_workers!(server)
            LS.start_analysis_worker!(server)
        end
        uri = LS.filepath2uri(entryfile)
        entry = target_module === nothing ? LS.ScriptInEnvAnalysisEntry(spec.environment,uri) :
            LS.NewAnalysisEntry(Base.PkgId(target_module),spec.environment)
        LS.cache_file_info!(server,uri,1,read(entryfile,String))
        completion = Base.Event()
        with_logger(logger) do
            LS.schedule_analysis!(server,uri,entry,false; completion,notify_diagnostics=false,debounce=0.0)
            wait(completion)
        end
        info = LS.get_analysis_info(server.state.analysis_manager,uri)
        info isa LS.AnalysisResult || error("No full analysis result: $(typeof(info))")
        info.entry == entry || error("Analysis result belongs to a different entry")
        covered = LS.collect_workspace_uris(server)
        diagnostics = LS.get_full_diagnostics(server)
        progress = LS.ProgressContext(LS.PROGRESS_SIMPLE,stderr)
        with_logger(logger) do
            LS.run_per_file_diagnostics!(diagnostics,covered,server,spec.root,progress;skip_analysis=false)
        end
        rows = diagnostic_rows(diagnostics)
        analyzed = sort!(String[LS.uri2filepath(u) for u in keys(info.analyzed_file_infos) if LS.uri2filepath(u)!==nothing])
        canonical_covered = Set(canonical.(analyzed))
        missing = filter(file -> canonical(file) ∉ canonical_covered, job.expected)
        isrevise = entry isa LS.NewAnalysisEntry
        signature_rows = signatures(info)
        signatures_verified = all(row -> row["analysis_verified"],signature_rows)
        context_complete = !any(omission -> omission.kind == "include",omissions)
        complete = (isrevise || info.complete) && context_complete && signatures_verified && isempty(missing) && isempty(logger.errors) &&
            isempty(job.blocking_issues) && !any(row -> row["code"] in BLOCKING_CODES,rows)
        result["analysis_entry"] = string(typeof(entry))
        result["analyzed_files"] = analyzed
        result["analyzed_uris"] = sort!(string.(collect(keys(info.analyzed_file_infos))))
        result["missing_files"] = missing
        result["diagnostics"] = rows
        result["signatures"] = signature_rows
        result["signature_inventory_basis"] = isrevise ? "Revise analysis work queue, each signature checked for an attached completed JETLS result" : "Retained JET inference cache only; this is not a complete list of interpreter analysis calls"
        result["jetls_include_traversal_complete"] = info.complete
        result["completion_basis"] = isrevise ? "Awaited Revise signature worker queue and verified expected-file coverage" : "JETLS interpreter complete flag and verified expected-file coverage"
        result["full_analysis_complete"] = complete
        result["status"] = !complete ? "analysis_incomplete" : isempty(rows) ? "clean" : "findings"
    catch exception
        result["status"] = exception isa UnsupportedBackend ? "unsupported_backend" : "analysis_incomplete"
        result["error"] = sprint(showerror,exception,catch_backtrace())
        result["full_analysis_complete"] = false
    finally
        if server !== nothing
            try
                LS.cleanup_cli_tasks(server)
            catch exception
                push!(logger.errors,"Worker cleanup failed: " * sprint(showerror,exception))
            end
        end
    end
    result["internal_errors"] = logger.errors
    result["active_project_after_analysis"] = something(Base.active_project(),"")
    result["effective_load_paths_after_analysis"] = copy(LOAD_PATH)
    conflicts = Dict{String,Any}[]
    preference_conflicts = Dict{String,Any}[]
    try
        checks, conflicts = dependency_verification(dependencies)
        result["dependency_identity_checks"] = checks
        result["dependency_identity_conflicts"] = conflicts
        if length(target_preferences) == length(dependencies)
            preference_checks, preference_conflicts = preference_verification(dependencies,loaded_preferences,target_preferences)
            result["preference_identity_checks"] = preference_checks
            result["preference_identity_conflicts"] = preference_conflicts
        end
    catch exception
        push!(logger.errors,"Runtime dependency identity verification failed: " * sprint(showerror,exception))
    end
    after = Dict(file=>digest(file) for file in keys(before))
    result["source_hashes_before"] = before
    result["source_hashes_after"] = after
    result["changed_inputs"] = sort!([file for file in keys(before) if before[file] != after[file]])
    try
        result["loaded_extensions"] = loaded_extensions()
    catch exception
        push!(logger.errors,"Extension inventory failed: " * sprint(showerror,exception))
    end
    if !isempty(result["changed_inputs"])
        result["status"] = "source_changed"
        result["full_analysis_complete"] = false
    elseif !isempty(logger.errors) || !isempty(conflicts) || !isempty(preference_conflicts)
        result["status"] = "analysis_incomplete"
        result["full_analysis_complete"] = false
    end
    return result
end

function main(arguments=copy(ARGS), startup_errors::Vector{String}=String[])
    length(arguments) == 2 || error("usage: analyze.jl JOB.toml RESULT.toml")
    jobfile, output = abspath.(arguments)
    result = try
        analyze(read_spec(jobfile),output,startup_errors)
    catch exception
        Dict{String,Any}("schema_version"=>1,"status"=>"analysis_incomplete",
            "full_analysis_complete"=>false,"error"=>sprint(showerror,exception,catch_backtrace()))
    end
    mkpath(dirname(output))
    temporary = output * ".tmp"
    open(io -> TOML.print(io,result; sorted=true),temporary,"w")
    mv(temporary,output;force=true)
    println("JETSWEEP_WORKER ",result["status"])
    return get(result,"full_analysis_complete",false) ? 0 : 1
end

end # module JETSweepBackend
