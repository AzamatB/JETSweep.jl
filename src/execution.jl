const _LOADED_PROJECT = Ref("")

"The project JETSweep was loaded from, which also provides JETLS to analysis environments."
tool_project() = _LOADED_PROJECT[]

function _write_toml(path::String, data)
    mkpath(dirname(path))
    open(io -> TOML.print(io, data; sorted=true), path, "w")
    return path
end

# Scheduling
# ==========

"Work for the dispatcher: preparing the environment of a context, or analyzing a unit."
struct _Task
    weight::Int
    priority::Tuple{Int,Int}
    work::Union{Context,Unit}
end

"""
Run `step(task)` for every task on `capacity` CPU slots, in priority order. A task that
does not fit waits for slots rather than letting later tasks pass it, so heavy tasks
cannot starve. `step` returns follow-up tasks.
"""
function _dispatch(step, tasks::Vector{_Task}, capacity::Int)
    queue = sort(tasks; by=task -> task.priority)
    condition = Threads.Condition()
    used, running = 0, 0
    failure = Ref{Any}(nothing)
    try
        @lock condition while true
            while !isempty(queue) && failure[] === nothing && used + min(first(queue).weight, capacity) <= capacity
                task = popfirst!(queue)
                weight = min(task.weight, capacity)
                used += weight
                running += 1
                @async begin
                    followups = _Task[]
                    try
                        followups = step(task)
                    catch err
                        failure[] = CapturedException(err, catch_backtrace())
                    end
                    @lock condition begin
                        used -= weight
                        running -= 1
                        for followup in followups
                            index = searchsortedfirst(queue, followup; by=task -> task.priority)
                            insert!(queue, index, followup)
                        end
                        notify(condition)
                    end
                end
            end
            running == 0 && (isempty(queue) || failure[] !== nothing) && break
            wait(condition)
        end
    catch
        _terminate_all()
        rethrow()
    end
    failure[] === nothing || throw(failure[])
    return nothing
end

# Environments
# ============

_context_key(context::Context) = bytes2hex(sha256(string(context.project, '\0', context.owner, '\0', context.test,
    '\0', join(sort!(["$k=$v" for (k, v) in context.triggers]), '\0'))))[1:12]

function _prepare(context::Context, directory::String, options::SweepOptions)
    request = _write_toml(joinpath(directory, "request.toml"), Dict(
        "project" => context.project, "owner" => context.owner, "test" => context.test,
        "triggers" => context.triggers, "directory" => joinpath(directory, "env"),
        "instantiate" => options.instantiate))
    result = joinpath(directory, "result.toml")
    log = joinpath(directory, "log.txt")
    command = julia_command(joinpath(_SCRIPTS, "prepare.jl"), [request, result];
        project=dirname(tool_project()), threads=1, env=Dict("JULIA_NUM_PRECOMPILE_TASKS" => "2"))
    process = run_worker(command, log, options.timeout)
    if process.timed_out
        return Environment(:failed, joinpath(directory, "env"), "environment preparation timed out; see $log")
    elseif !isfile(result)
        return Environment(:failed, joinpath(directory, "env"), "environment preparation exited with code $(process.code); see $log")
    end
    data = TOML.parsefile(result)
    return Environment(Symbol(data["status"]), data["dir"], data["message"])
end

# Units
# =====

const _SCRIPTS = joinpath(dirname(@__DIR__), "scripts")

"The `.JETLSConfig.toml` that applies to a unit: configured, or the nearest above its entry."
function _jetls_config(unit::Unit, root::String)
    isempty(unit.overrides.jetls_config) || return unit.overrides.jetls_config
    directory = dirname(unit.entry)
    while true
        file = joinpath(directory, ".JETLSConfig.toml")
        isfile(file) && return file
        (directory == root || !_within(directory, root)) && return ""
        directory = dirname(directory)
    end
end

"A path as a literal glob: JETLS matches configured paths with escapes enabled."
_glob_literal(path::AbstractString) = replace(_slash(path), r"([\\*?\[\]])" => s"\\\1")

const _PATH_SETTINGS = (("diagnostic", "patterns"), ("full_analysis", "concretization_patterns"),
                        ("initialization_options", "analysis_overrides"))

"""
Write the unit's JETLS configuration and return the root its paths are relative to, the
sweep root. The user's configuration applies with its paths rebased from its own
directory, plus the settings a sweep requires.

Script analysis may also evaluate the unit's statically side-effect-free top-level
statements (`concretization_patterns`), so that definitions and includes depending on their
values load. A test driver whose run-time includes are analyzed as their own units also
evaluates the assignments that select those files, and then skips including them.
"""
function _write_jetls_config(unit::Unit, directory::String, root::String, separate::Vector{String})
    source = _jetls_config(unit, root)
    data = isempty(source) ? Dict{String,Any}() : TOML.parsefile(source)
    prefix = isempty(source) ? "." : relpath(dirname(source), root)
    for (section, key) in _PATH_SETTINGS, entry in get(get(data, section, Dict()), key, Any[])
        prefix != "." && entry isa AbstractDict && get(entry, "path", nothing) isa String &&
            (entry["path"] = _glob_literal(prefix) * "/" * entry["path"])
    end
    full = get!(data, "full_analysis", Dict{String,Any}())
    full["auto_instantiate"] = "never"   # JETSweep prepares every environment itself
    diagnostic = get!(data, "diagnostic", Dict{String,Any}())
    diagnostic["enabled"] = true
    diagnostic["all_files"] = true
    if unit.kind in (:test, :script, :orphan)
        patterns = get!(full, "concretization_patterns", Any[])
        for file in [unit.expected; unit.overrides.setup]
            path = _glob_literal(relpath(file, root))
            for pattern in concretization_patterns(file; selection=file == unit.entry && !isempty(separate))
                push!(patterns, Dict("pattern" => pattern, "path" => path))
            end
        end
    end
    if !isempty(separate)
        overrides = get!(get!(data, "initialization_options", Dict{String,Any}()), "analysis_overrides", Any[])
        for file in separate
            push!(overrides, Dict("path" => _glob_literal(relpath(file, root)), "on_include" => "skip"))
        end
    end
    _write_toml(joinpath(directory, "config", ".JETLSConfig.toml"), data)
    return root
end

"The entry file analyzed for a test or script unit: its context, then the original file."
function _generated_entry(unit::Unit)
    io = IOBuffer()
    println(io, "# Generated by JETSweep for ", unit.entry)
    println(io, "const Main = @__MODULE__")
    isempty(unit.driver) || print(io, prelude(unit.driver, unit.entry))
    for file in unit.overrides.setup
        println(io, "include(", repr(file), ")")
    end
    println(io, "include(", repr(unit.entry), ")")
    return String(take!(io))
end

function _package(unit::Unit, inventory::Inventory)
    index = findfirst(project -> project.dir == unit.context.owner, inventory.projects)
    index === nothing && return ("", "")
    return (inventory.projects[index].name, inventory.projects[index].uuid)
end

function _analyze(unit::Unit, environment::Environment, inventory::Inventory, output::String,
                  options::SweepOptions, gpu::Union{Nothing,String}, separate::Vector{String})
    directory = joinpath(output, "units", unit.id)
    mkpath(directory)
    log = joinpath(directory, "log.txt")
    started = time()
    failure(status, reason, seconds=time() - started) =
        UnitResult(unit.id, status, Finding[], String[], [reason], String[], seconds, log)
    ready(environment) || return failure(:unavailable, "environment unavailable: " * environment.message, 0.0)
    generated = joinpath(directory, "entry.jl")
    unit.kind in (:test, :script) && write(generated, _generated_entry(unit))
    name, uuid = _package(unit, inventory)
    request = _write_toml(joinpath(directory, "request.toml"), Dict(
        "kind" => String(unit.kind), "entry" => unit.entry, "expected" => unit.expected,
        "environment" => environment.dir, "generated" => generated,
        "config" => joinpath(directory, "config"), "root" => _write_jetls_config(unit, directory, inventory.root, separate),
        "package" => name, "uuid" => uuid, "extension" => unit.extension, "triggers" => unit.context.triggers,
        "args" => unit.overrides.args, "env" => unit.overrides.env))
    result = joinpath(directory, "result.toml")
    threads = unit.kind in (:package, :extension) ? options.threads : 1
    command = julia_command(joinpath(_SCRIPTS, "analyze.jl"), [request, result]; project=environment.dir,
        threads, compile=false, env=gpu === nothing ? Dict{String,String}() : Dict("CUDA_VISIBLE_DEVICES" => gpu))
    process = run_worker(Cmd(command; dir=dirname(unit.entry)), log, options.timeout)
    process.timed_out && return failure(:timeout, "time limit of $(options.timeout) s exceeded")
    isfile(result) || return failure(:failed, "worker exited with code $(process.code) without a result")
    data = TOML.parsefile(result)
    haskey(data, "error") && return failure(:failed, first(split(data["error"], '\n')))
    reasons = String[data["reasons"]..., ("logged error: " * error for error in data["errors"])...]
    # Files the analysis did not reach are analyzed by follow-up units; see `_followups`.
    notes = isempty(data["missing"]) ? String[] : ["not reached by this analysis: " * join(data["missing"], ", ")]
    found = [Finding(row["file"], row["line"], row["column"], row["end_line"], row["end_column"],
                     row["severity"], row["code"], row["message"]) for row in data["findings"]]
    status = !isempty(reasons) ? :incomplete : isempty(found) ? :clean : :findings
    return UnitResult(unit.id, status, found, data["analyzed"], reasons, notes, time() - started, log)
end

"""
Units for the files a unit expected to cover but did not reach. Package and extension files
that loading left out, such as conditionally included code, become orphan units. Files a
test or script did not reach, after an analysis stop say, are analyzed from themselves in
the same context.
"""
function _followups(unit::Unit, result::UnitResult, inventory::Inventory, planned::Set{String},
                    sources::Dict{String,Source})
    result.status in (:clean, :findings, :incomplete) && !isempty(result.analyzed) || return Unit[]
    analyzed = Set(result.analyzed)
    missed = filter(file -> !(realpath(file) in analyzed) && !(file in planned), unit.expected)
    isempty(missed) && return Unit[]
    if unit.kind in (:package, :extension, :orphan)
        context = Context(unit.context.owner, unit.context.owner, false, Dict{String,String}())
        return [Unit(_unit_id(:orphan, file, inventory.root), :orphan, file, context, [file], "", "",
                     Overrides(), ["not included when its package loaded"]) for file in missed]
    end
    syntax = Dict(file => parse_source(file) for file in missed)
    return [Unit(_unit_id(unit.kind, entry, inventory.root), unit.kind, entry, unit.context, expected,
                 unit.kind === :test ? _driver(entry, unit.context.owner, sources) : "", "", unit.overrides,
                 ["not reached when analyzing $(unit.entry)"]) for (entry, expected) in _entries(missed, syntax)]
end

"""
Seconds each unit took in the latest report below `root/.jetsweep`, by unit id. Unit ids
are stable across runs, so a repeated sweep can start its longest analyses first.
"""
function _previous_seconds(root::String)
    directory = joinpath(root, ".jetsweep")
    reports = isdir(directory) ? filter(isfile, joinpath.(readdir(directory; join=true), "report.toml")) : String[]
    isempty(reports) && return Dict{String,Float64}()
    try
        return Dict{String,Float64}(r["unit"] => r["seconds"] for r in TOML.parsefile(argmax(mtime, reports))["results"])
    catch
        return Dict{String,Float64}()
    end
end

"Estimated seconds a unit takes: its previous duration, or a guess from its source size."
_cost(unit::Unit, previous::Dict{String,Float64}) =
    get(previous, unit.id) do
        10.0 + sum(file -> isfile(file) ? filesize(file) : 0, unit.expected; init=0) / 1000
    end

# Environments first, since units wait for them, those with the most work first; then the
# longest analyses. Package and extension analyses use `threads` slots.
_task(context::Context, units, previous) =
    _Task(2, (0, -round(Int, sum(unit -> _cost(unit, previous), units; init=0.0))), context)
_task(unit::Unit, options::SweepOptions, previous) =
    _Task(unit.kind in (:package, :extension) ? options.threads : 1, (1, -round(Int, _cost(unit, previous))), unit)

"Values for each worker's `CUDA_VISIBLE_DEVICES`; `\"\"` hides all devices, none leaves it unset."
function _gpus(requested::Vector{String})::Vector{String}
    requested == ["none"] && return [""]
    requested == ["auto"] || return requested
    visible = get(ENV, "CUDA_VISIBLE_DEVICES", nothing)
    visible === nothing || return isempty(strip(visible)) ? [""] : String.(strip.(split(visible, ',')))
    smi = Sys.which("nvidia-smi")
    smi === nothing && return String[]
    try
        return String.(filter(!isempty, strip.(readlines(`$smi --query-gpu=uuid --format=csv,noheader`))))
    catch
        return String[]
    end
end

"Hashes of every inventoried source and project metadata file, to detect edits during a run."
function _snapshot(inventory::Inventory, config::Config)
    files = Set(source.path for source in inventory.sources)
    isempty(config.file) || push!(files, config.file)
    for project in inventory.projects
        for name in readdir(project.dir)
            (name in _PROJECT_FILES || occursin(r"^(Julia)?(Manifest|LocalPreferences)(-v[\d.]+)?\.toml$", name) ||
             name == ".JETLSConfig.toml") && push!(files, joinpath(project.dir, name))
        end
    end
    return Dict(file => bytes2hex(open(sha256, file)) for file in files if isfile(file))
end

"""
    sweep(root; options=SweepOptions(), io=stderr) -> SweepResult

Discover, plan and analyze everything below `root`, writing a report directory. Every
unit runs JETLS in its own process, in a prepared environment shared by units with the
same dependency context.
"""
function sweep(root::AbstractString; options::SweepOptions=SweepOptions(), io::IO=stderr)
    options.jobs > 0 || throw(ArgumentError("jobs must be positive"))
    options.threads > 0 || throw(ArgumentError("threads must be positive"))
    0 <= options.timeout < Inf || throw(ArgumentError("timeout must be finite and nonnegative"))
    options.fail_on in (SEVERITIES..., :none) || throw(ArgumentError("invalid failure severity $(options.fail_on)"))
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    started = time()
    root = realpath(root)
    config = read_config(root, options.config)
    output = isempty(options.output) ?
        joinpath(root, ".jetsweep", Libc.strftime("%Y%m%d-%H%M%S", time())) : abspath(options.output)
    ispath(output) && !(isdir(output) && isempty(readdir(output))) &&
        throw(ArgumentError("report directory must be new or empty: $output"))
    inventory = discover(root; exclude=[config.exclude; options.exclude], output,
                         include_ignored=options.include_ignored, tracked_only=options.tracked_only)
    units = plan(inventory, config)
    mkpath(output)
    write_inventory(joinpath(output, "inventory.toml"), inventory)
    write_plan(joinpath(output, "plan.toml"), units, inventory.root)
    contexts = unique(unit.context for unit in units)
    packages = count(ispackage, inventory.projects)
    println(io, "JETSweep: $(length(inventory.sources)) files, $packages packages, $(length(units)) units, ",
            "$(length(contexts)) environments")
    if options.plan_only
        println(io, "Plan written to $output")
        return SweepResult(root, output, inventory, units, UnitResult[], String[], time() - started,
                           isempty(inventory.issues) ? 0 : 2)
    end
    before = _snapshot(inventory, config)
    gpus = _gpus(options.gpus)
    previous = _previous_seconds(root)
    members = Dict(context => filter(unit -> unit.context == context, units) for context in contexts)
    separate = Dict{String,Vector{String}}()
    foreach(unit -> isempty(unit.driver) || push!(get!(separate, unit.driver, String[]), unit.entry), units)
    environments = Dict{Context,Environment}()
    results = Dict{String,UnitResult}()
    sources = Dict(source.path => source for source in inventory.sources)
    # Files some unit's entry already covers need no follow-up units of their own.
    planned = Set(unit.entry for unit in units)
    started_units = Ref(0)
    # A failure handling one environment or unit is recorded as its result, not raised.
    contained(f, failed) = try
        f()
    catch err
        err isa InterruptException && rethrow()
        failed(sprint(showerror, err))
    end
    function step(task::_Task)
        work = task.work
        if work isa Context
            directory = joinpath(output, "environments", _context_key(work))
            environments[work] = contained(() -> _prepare(work, directory, options),
                                           message -> Environment(:failed, directory, message))
            return [_task(unit, options, previous) for unit in members[work]]
        end
        gpu = isempty(gpus) ? nothing : gpus[mod1(started_units[] += 1, length(gpus))]
        result = contained(() -> _analyze(work, environments[work.context], inventory, output, options, gpu,
                                          work.kind === :test ? get(separate, work.entry, String[]) : String[]),
                           message -> UnitResult(work.id, :failed, Finding[], String[], [message], String[], 0.0, ""))
        results[work.id] = result
        report_progress(io, work, result, length(results), length(units), root)
        followups = _followups(work, result, inventory, planned, sources)
        for unit in followups
            union!(planned, unit.expected)
            push!(units, unit)
        end
        return [_task(unit, options, previous) for unit in followups]
    end
    _dispatch(step, [_task(context, members[context], previous) for context in contexts], options.jobs)
    after = _snapshot(discover(root; exclude=[config.exclude; options.exclude], output,
                               include_ignored=options.include_ignored, tracked_only=options.tracked_only), config)
    changed = sort!([file for file in union(keys(before), keys(after)) if get(before, file, "") != get(after, file, "")])
    ordered = [results[unit.id] for unit in units]
    code = exit_code(inventory, ordered, changed, options.fail_on)
    result = SweepResult(root, output, inventory, units, ordered, changed, time() - started, code)
    write_report(result; io)
    return result
end
