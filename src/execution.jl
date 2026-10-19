const _LOADED_PROJECT = Ref("")

"The project JETSweep was loaded from, which also provides JETLS to analysis environments."
tool_project() = _LOADED_PROJECT[]

_timestamp() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

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

"""
Write the unit's JETLS configuration: the user's, with the settings a sweep requires, and
return the directory its paths are relative to. A test driver whose run-time includes are
analyzed as their own units evaluates its constants, so that analysis gets past its
selection logic, and skips those includes.
"""
function _write_jetls_config(unit::Unit, directory::String, root::String, separate::Vector{String})
    source = _jetls_config(unit, root)
    base = isempty(source) ? root : dirname(source)
    data = isempty(source) ? Dict{String,Any}() : TOML.parsefile(source)
    full = get!(data, "full_analysis", Dict{String,Any}())
    full["auto_instantiate"] = "never"   # JETSweep prepares every environment itself
    diagnostic = get!(data, "diagnostic", Dict{String,Any}())
    diagnostic["enabled"] = true
    diagnostic["all_files"] = true
    if !isempty(separate)
        push!(get!(full, "concretization_patterns", Any[]),
              Dict("pattern" => "const x_ = y_", "path" => _slash(relpath(unit.entry, base))))
        overrides = get!(get!(data, "initialization_options", Dict{String,Any}()), "analysis_overrides", Any[])
        for file in separate
            push!(overrides, Dict("path" => _slash(relpath(file, base)), "on_include" => "skip"))
        end
    end
    _write_toml(joinpath(directory, "config", ".JETLSConfig.toml"), data)
    return base
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
        threads, env=gpu === nothing ? Dict{String,String}() : Dict("CUDA_VISIBLE_DEVICES" => gpu))
    process = run_worker(Cmd(command; dir=dirname(unit.entry)), log, options.timeout)
    process.timed_out && return failure(:timeout, "time limit of $(options.timeout) s exceeded")
    isfile(result) || return failure(:failed, "worker exited with code $(process.code) without a result")
    data = TOML.parsefile(result)
    haskey(data, "error") && return failure(:failed, first(split(data["error"], '\n')))
    reasons = String[data["reasons"]..., ("logged error: " * error for error in data["errors"])...]
    notes = String[]
    if !isempty(data["missing"])
        # A package's conditionally included files are analyzed as orphan units instead.
        unit.kind in (:package, :extension) ?
            push!(notes, "loading did not include: " * join(data["missing"], ", ")) :
            push!(reasons, "not analyzed: " * join(data["missing"], ", "))
    end
    found = [Finding(row["file"], row["line"], row["column"], row["end_line"], row["end_column"],
                     row["severity"], row["code"], row["message"]) for row in data["findings"]]
    status = !isempty(reasons) ? :incomplete : isempty(found) ? :clean : :findings
    return UnitResult(unit.id, status, found, data["analyzed"], reasons, notes, time() - started, log)
end

"""
Orphan units for the files a package or extension unit expected to cover but its loaded
module did not include, such as conditionally included code.
"""
function _missed_sources(unit::Unit, result::UnitResult, inventory::Inventory, planned::Set{String})
    unit.kind in (:package, :extension) && !isempty(result.analyzed) || return Unit[]
    analyzed = Set(result.analyzed)
    missed = filter(file -> !(realpath(file) in analyzed) && !(file in planned), unit.expected)
    return [Unit(_unit_id(:orphan, file, inventory.root), :orphan, file,
                 Context(unit.context.owner, unit.context.owner, false, Dict{String,String}()), [file], "", "",
                 Overrides(), ["loading the package did not include this file"]) for file in missed]
end

"Source bytes a unit analyzes, the scheduler's estimate of its cost."
_cost(unit::Unit) = sum(file -> isfile(file) ? filesize(file) : 0, unit.expected; init=0)

# Environments first, since units wait for them; then the longest analyses, packages first.
_task(context::Context, units) = _Task(2, (0, -sum(_cost, units; init=0)), context)
_task(unit::Unit, options::SweepOptions) = unit.kind in (:package, :extension) ?
    _Task(options.threads, (1, -_cost(unit)), unit) : _Task(1, (2, -_cost(unit)), unit)

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
        joinpath(root, ".jetsweep", Dates.format(Dates.now(Dates.UTC), "yyyymmdd-HHMMSS")) : abspath(options.output)
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
    members = Dict(context => filter(unit -> unit.context == context, units) for context in contexts)
    separate = Dict{String,Vector{String}}()
    foreach(unit -> isempty(unit.driver) || push!(get!(separate, unit.driver, String[]), unit.entry), units)
    environments = Dict{Context,Environment}()
    results = Dict{String,UnitResult}()
    planned = Set(unit.entry for unit in units)
    started_units = Ref(0)
    function step(task::_Task)
        work = task.work
        if work isa Context
            environments[work] = _prepare(work, joinpath(output, "environments", _context_key(work)), options)
            return [_task(unit, options) for unit in members[work]]
        end
        gpu = isempty(gpus) ? nothing : gpus[mod1(started_units[] += 1, length(gpus))]
        result = _analyze(work, environments[work.context], inventory, output, options, gpu,
                          work.kind === :test ? get(separate, work.entry, String[]) : String[])
        results[work.id] = result
        report_progress(io, work, result, length(results), length(units), root)
        orphans = _missed_sources(work, result, inventory, planned)
        for orphan in orphans
            push!(planned, orphan.entry)
            push!(units, orphan)
        end
        return [_task(orphan, options) for orphan in orphans]
    end
    _dispatch(step, [_task(context, members[context]) for context in contexts], options.jobs)
    after = _snapshot(discover(root; exclude=[config.exclude; options.exclude], output,
                               include_ignored=options.include_ignored, tracked_only=options.tracked_only), config)
    changed = sort!([file for file in union(keys(before), keys(after)) if get(before, file, "") != get(after, file, "")])
    ordered = [results[unit.id] for unit in units]
    code = exit_code(inventory, ordered, changed, options.fail_on)
    result = SweepResult(root, output, inventory, units, ordered, changed, time() - started, code)
    write_report(result; io)
    return result
end
