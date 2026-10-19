# JETSweep analysis worker: analyzes one unit and writes its result.
#
#     julia --project=ENVIRONMENT analyze.jl REQUEST.toml RESULT.toml
#
# ENVIRONMENT is the unit's prepared analysis environment. It provides JETLS with its
# Revise-based package analysis enabled, and the unit's own dependencies, resolved together
# so that both use the same version of every shared package. The worker loads nothing else.
module JETSweepWorker

using JETLS, TOML

const LS = Base.require(JETLS, :JETLSCore)

# JET outlines a test expression into a thunk when it defines an anonymous function in a
# conditional branch, as in `@test isnothing(x) || all(y -> y > 0, x)`, because realizing a
# closure there concretely executes the conditions before it: the test itself, in JET's
# interpreter. Generators and comprehensions define closures too, so treat them alike;
# otherwise `@test r.ok && [a.b for a in r.items] == [1]` runs whatever computes `r`.
Core.eval(LS.JET, quote
    function is_anonymous_test_function(@nospecialize(ex))
        isexpr(ex, (:->, :generator, :flatten, :comprehension, :typed_comprehension)) && return true
        isexpr(ex, :function, 2) || return false
        sig = first(ex.args)
        while isexpr(sig, (:(::), :where)) && !isempty(sig.args)
            sig = first(sig.args)
        end
        return isexpr(sig, :tuple)
    end
end)
# JETLS dispatches in the world it was loaded in, to stay clear of analyzed code.
LS.advance_server_world!()

# Codes after which JETLS analyzes no further code of the unit. JET stops at any parse
# error, which JETLS reports only as a syntax diagnostic.
const STOPS = ("toplevel/error", "toplevel/missing-concretization", "toplevel/concretization-timeout",
               "toplevel/analysis-stopped", "syntax/parse-error")

"""
Collects error-level log records. The analyzer's errors signal analysis problems it does not
raise. Julia's loader logs, rather than raises, the failure of a package extension.
"""
struct ErrorLog{L<:Base.CoreLogging.AbstractLogger} <: Base.CoreLogging.AbstractLogger
    parent::L
    analyzer::Vector{String}
    loading::Vector{String}
    lock::ReentrantLock
end
ErrorLog(parent) = ErrorLog(parent, String[], String[], ReentrantLock())
Base.CoreLogging.min_enabled_level(log::ErrorLog) = Base.CoreLogging.min_enabled_level(log.parent)
Base.CoreLogging.shouldlog(log::ErrorLog, args...) = Base.CoreLogging.shouldlog(log.parent, args...)
Base.CoreLogging.catch_exceptions(::ErrorLog) = false
"The exception a log record carries, which loggers accept bare, with a backtrace or as a stack."
_exception(e) = e isa Exception ? e : e isa Base.ExceptionStack ? (isempty(e) ? e : _exception(last(e))) :
    e isa NamedTuple && haskey(e, :exception) ? _exception(e.exception) : e isa Tuple ? _exception(first(e)) : e
function Base.CoreLogging.handle_message(log::ErrorLog, level, message, _module, args...; kwargs...)
    if level >= Base.CoreLogging.Error && _module isa Module
        text = string(message)
        haskey(kwargs, :exception) && (text *= " " * sprint(showerror, _exception(kwargs[:exception])))
        origin = nameof(Base.moduleroot(_module))
        @lock log.lock push!(origin in (:JETLSCore, :JETLS, :JET, :Revise) ? log.analyzer :
                             origin === :Base ? log.loading : String[], text)
    end
    return Base.CoreLogging.handle_message(log.parent, level, message, _module, args...; kwargs...)
end

canonical(path::AbstractString) = ispath(path) ? realpath(path) : abspath(path)

"Load a package, or an extension with its parent and triggers, and return its module."
function load(request, log::ErrorLog)
    package = Base.PkgId(Base.UUID(request["uuid"]), request["package"])
    parent = Base.require(package)
    # Revise resolves a file's outer `module` block by name; bind the loaded module so a
    # single-file package is not attributed to `Base.__toplevel__`.
    bind(parent)
    name = request["extension"]
    isempty(name) && return parent
    for (trigger, uuid) in sort!(collect(request["triggers"]); by=first)
        Base.require(Base.PkgId(Base.UUID(uuid), trigger))
    end
    # A failed extension can still be registered, half defined, so check the loader's log.
    failure = findfirst(text -> occursin("extension $name ", text), log.loading)
    failure === nothing || error("extension $name failed to load: ", log.loading[failure])
    extension = Base.get_extension(parent, Symbol(name))
    extension isa Module || error("extension $name did not load with its triggers")
    request["kind"] == "extension" && canonical(something(pathof(extension), "")) != canonical(request["entry"]) &&
        error("extension $name loaded from $(pathof(extension)), not $(request["entry"])")
    bind(extension)
    return extension
end

function bind(mod::Module)
    name = nameof(mod)
    if !isdefined(Base.__toplevel__, name)
        Core.eval(Base.__toplevel__, Expr(:const, Expr(:(=), name, mod)))
    end
    return nothing
end

"A binding's name as `import` syntax takes it, or `nothing`."
function import_name(name::Symbol)
    text = String(name)
    startswith(text, '#') && return nothing
    text = Base.isidentifier(name) || Base.isoperator(name) || startswith(text, '@') ? text : "var$(repr(text))"
    return Meta.isexpr(Meta.parse("import M: $text"; raise=false), :import) ? text : nothing
end

"""
An entry file that recreates the scope of `target`, a package's module or an extension's,
before including `file`: the modules it uses and every binding it defines or imports. A
used module is named through `target` when `target` binds it, since its package need not be
loadable from the environment by name: a dependency of a dependency, say. An extension is
reached through its package, since it has no name to load it by.
"""
function orphan_entry(target::Module, file::String, package::String, extension::String)
    io = IOBuffer()
    println(io, "const Main = @__MODULE__\nimport ", package)
    reference = package
    if !isempty(extension)
        # Evaluated, so that analysis knows the module.
        println(io, "@eval const ", extension, " = Base.get_extension(", package, ", :", extension, ")")
        reference = "." * extension
    end
    path(m) = isdefined(target, nameof(m)) && getglobal(target, nameof(m)) === m ?
        "$reference.$(nameof(m))" : join(fullname(m), '.')
    for m in ccall(:jl_module_usings, Any, (Any,), target)
        m === Base || m === Core || m === target || first(fullname(m)) === :Main || println(io, "using ", path(m))
    end
    bindings = [text for name in names(target; all=true, imported=true)
                if !(name in (:eval, :include)) && isdefined(target, name)
                for text in (import_name(name),) if text !== nothing]
    isempty(bindings) || println(io, "import ", reference, ": ", join(bindings, ", "))
    println(io, "include(", repr(file), ")")
    return String(take!(io))
end

"`target` and the modules defined inside it."
function modules(target::Module, found=Module[target])
    for name in names(target; all=true)
        isdefined(target, name) || continue
        value = getglobal(target, name)
        value isa Module && value !== target && parentmodule(value) === target && !(value in found) &&
            (push!(found, value); modules(value, found))
    end
    return found
end

"""
`toplevel/abstract-field` reports for the structs of a loaded package. JETLS reports these
while interpreting top-level code, which its package analysis loads instead.
"""
function abstract_fields(target::Module, files::Vector{String})
    trees = Dict(file => LS.JS.parseall(LS.JS.SyntaxNode, read(file, String); filename=file, ignore_errors=true)
                 for file in files)
    reports = LS.ToplevelWarningReport[]
    for mod in modules(target), name in names(mod; all=true)
        isdefined(mod, name) || continue
        value = getglobal(mod, name)
        value isa Type || continue
        type = Base.unwrap_unionall(value)
        type isa DataType && isstructtype(type) && parentmodule(type) === mod && nameof(type) === name &&
            !LS.is_closure_type(type) || continue
        for (fname, ftype) in zip(fieldnames(type), type.types)
            LS.is_abstract_fieldtype(ftype) || continue
            for (file, tree) in trees
                field = LS.try_extract_field_line(tree, name, fname)
                field === nothing && continue
                push!(reports, LS.AbstractFieldReport(file, field, value, fname, ftype))
                break
            end
        end
    end
    return reports
end

"Diagnostics of original files. Skipped includes are reported as missing coverage instead."
function findings(uri2diagnostics, generated::String)
    rows = Dict{String,Any}[]
    for (uri, diagnostics) in uri2diagnostics, diagnostic in diagnostics
        file = LS.uri2filepath(uri)
        (file === nothing || canonical(file) == generated) && continue
        diagnostic.code == "toplevel/analysis-skipped" && continue
        range = diagnostic.range
        push!(rows, Dict{String,Any}("file" => file,
            "line" => range.start.line + 1, "column" => range.start.character + 1,
            "end_line" => range.var"end".line + 1, "end_column" => range.var"end".character + 1,
            "severity" => Int(something(diagnostic.severity, LS.DiagnosticSeverity.Error)),
            "code" => string(something(diagnostic.code, "")), "message" => LS.get_raw_message(diagnostic)))
    end
    sort!(unique!(rows); by=row -> (row["file"], row["line"], row["column"], row["code"], row["message"]))
    return rows
end

function analyze(request, log::ErrorLog)
    timings = Dict{String,Float64}()
    started = time()
    environment = request["environment"]
    kind = request["kind"]
    LS.JETLS_VERSION[] = JETLS.JETLS_VERSION
    LS.JETLS_MODULE[] = JETLS
    LS.Revise === nothing && error("JETLS was loaded without its Revise backend (JETLS_DEV_MODE)")
    Base.ACTIVE_PROJECT[] = joinpath(environment, "Project.toml")
    empty!(LOAD_PATH)
    push!(LOAD_PATH, "@", "@stdlib")
    empty!(ARGS)
    append!(ARGS, request["args"])
    merge!(ENV, request["env"])
    # An empty module keeps worker globals out of reach of analyzed code. JET finds the
    # context by its path from `Main`.
    LS.FULL_ANALYSIS_CONTEXT[] = Core.eval(Main, :(module JETSweepAnalysis end))
    target = nothing
    if kind in ("package", "extension", "orphan")
        target = load(request, log)
        timings["load"] = time() - started
        if kind == "orphan"
            # The package's bindings exist only in the world after loading it.
            write(request["generated"], Base.invokelatest(orphan_entry, target, request["entry"], request["package"],
                                                          request["extension"]))
            target = nothing
        end
    end
    generated = canonical(request["generated"])
    cd(dirname(request["entry"]))
    server = LS.start_cli_server(request["config"])
    server.state.root_path = request["root"]
    server.state.workspaceFolders = [LS.filepath2uri(request["root"])]
    try
        LS.start_signature_analysis_workers!(server)
        LS.start_analysis_worker!(server)
        if target === nothing
            uri = LS.filepath2uri(generated)
            entry = LS.ScriptInEnvAnalysisEntry(environment, uri)
        else
            uri = LS.filepath2uri(request["entry"])
            entry = LS.NewAnalysisEntry(Base.PkgId(target), environment)
        end
        LS.cache_file_info!(server, uri, 1, read(LS.uri2filepath(uri), String))
        done = Base.Event()
        LS.schedule_analysis!(server, uri, entry, false; completion=done, notify_diagnostics=false, debounce=0.0)
        wait(done)
        mark = time()
        timings["analysis"] = mark - started - get(timings, "load", 0.0)
        info = LS.get_analysis_info(server.state.analysis_manager, uri)
        info isa LS.AnalysisResult || error("JETLS produced no analysis result: $(typeof(info))")
        files = [canonical(file) for file in (LS.uri2filepath(uri) for uri in keys(info.analyzed_file_infos))
                 if file !== nothing]
        uris = LS.collect_workspace_uris(server)
        diagnostics = LS.get_full_diagnostics(server)
        if target !== nothing
            reports = Base.invokelatest(abstract_fields, target, files)
            LS.toplevel_warning_reports_to_diagnostics!(diagnostics, reports, server, LS.JET.PostProcessor())
        end
        progress = LS.ProgressContext(LS.PROGRESS_NONE, stderr)
        LS.run_per_file_diagnostics!(diagnostics, uris, server, request["root"], progress; skip_analysis=false)
        # Before the user's severity configuration applies, which could turn the stops off.
        reasons = String[]
        for (uri, list) in diagnostics, diagnostic in list
            code = string(something(diagnostic.code, ""))
            code in STOPS || continue
            location = "$(something(LS.uri2filepath(uri), string(uri))):$(diagnostic.range.start.line + 1)"
            push!(reasons, "analysis stopped at $location [$code]: " *
                first(split(LS.get_raw_message(diagnostic), '\n')))
        end
        for (uri, list) in diagnostics
            LS.apply_diagnostic_config!(list, server.state.config_manager, uri, request["root"])
        end
        timings["lowering"] = time() - mark
        return Dict{String,Any}("analyzed" => sort!(filter(!=(generated), files)),
                                "findings" => findings(diagnostics, generated), "reasons" => unique!(reasons),
                                "timings" => timings)
    finally
        LS.cleanup_cli_tasks(server)
    end
end

function main(request_file::String, result_file::String)
    request = TOML.parsefile(request_file)
    log = ErrorLog(Base.CoreLogging.current_logger())
    result = try
        Base.CoreLogging.with_logger(() -> analyze(request, log), log)
    catch err
        Dict{String,Any}("error" => sprint(showerror, err, catch_backtrace()))
    end
    result["errors"] = log.analyzer
    # Whole or not at all, since JETSweep reads the result once the worker exits.
    open(io -> TOML.print(io, result; sorted=true), result_file * ".partial", "w")
    mv(result_file * ".partial", result_file; force=true)
    return 0
end

end # module JETSweepWorker

length(ARGS) == 2 || error("usage: analyze.jl REQUEST.toml RESULT.toml")
exit(JETSweepWorker.main(ARGS[1], ARGS[2]))
