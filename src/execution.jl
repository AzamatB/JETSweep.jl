const _LOADED_PROJECT = Ref("")

"The project JETSweep was loaded from, which also provides JETLS to analysis environments."
tool_project() = _LOADED_PROJECT[]

# Scheduling
# ==========

"Work for the dispatcher: preparing the environment of a context, or analyzing a unit."
struct _Task
    weight::Int
    priority::Tuple{Int,Int}
    work::Union{Context,Unit}
end

"""
The slots in use by all the dispatches of this process, and the most they may use together:
the `worker_cap()` of the moment when none was in use. Sweeps side by side, as the test suite
runs them, so fit the machine together. Dispatches wait on the shared condition, so that one
that frees slots wakes the others.
"""
const _SHARED = (condition=Threads.Condition(), used=Ref(0), cap=Ref(0))

"""
Run `step(task)` for every task on `capacity` CPU slots, in priority order, within the slots
the process has for all its dispatches (`_SHARED`; `cap()` sets their number when none is in
use). A task that does not fit waits for slots rather than letting later tasks pass it, so
heavy tasks cannot starve. `step` returns follow-up tasks. An interrupt stops every worker at once.
"""
function _dispatch(step, tasks::Vector{_Task}, capacity::Int; cap=worker_cap)
    queue = sort(tasks; by=task -> task.priority)
    condition = _SHARED.condition
    used, running = Ref(0), Ref(0)
    failure = Ref{Any}(nothing)
    try
        @lock condition while true
            # Ctrl-C interrupts whichever task is current, usually one waiting for its worker.
            failure[] isa InterruptException && throw(failure[])
            while !isempty(queue) && failure[] === nothing
                _SHARED.used[] == 0 && (_SHARED.cap[] = cap())
                weight = min(first(queue).weight, capacity, _SHARED.cap[])
                used[] + weight <= capacity && _SHARED.used[] + weight <= _SHARED.cap[] || break
                task = popfirst!(queue)
                used[] += weight
                _SHARED.used[] += weight
                running[] += 1
                @async begin
                    followups = _Task[]
                    try
                        followups = step(task)
                    catch err
                        failure[] = err isa InterruptException ? err : CapturedException(err, catch_backtrace())
                    end
                    @lock condition begin
                        used[] -= weight
                        _SHARED.used[] -= weight
                        running[] -= 1
                        for followup in followups
                            index = searchsortedfirst(queue, followup; by=task -> task.priority)
                            insert!(queue, index, followup)
                        end
                        notify(condition)
                    end
                end
            end
            running[] == 0 && (isempty(queue) || failure[] !== nothing) && break
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
    '\0', join(sort!(["$k=$v" for (k, v) in context.triggers]), '\0'),
    '\0', join(sort!(["$k=$v" for (k, v) in context.imports]), '\0'))))[1:12]

_environment_directory(output::String, context::Context) = joinpath(output, "environments", _context_key(context))

"""
Prepare the environment of `context` in a worker, in `directory`, which is also the worker's
working directory; `env` adds to the worker's environment variables.
"""
function _prepare(context::Context, directory::String, options::SweepOptions;
                  env::Dict{String,String}=Dict{String,String}())
    directory = abspath(directory)
    request = _write_toml(joinpath(directory, "request.toml"), Dict(
        "project" => context.project, "owner" => context.owner, "test" => context.test,
        "triggers" => context.triggers, "imports" => context.imports, "directory" => joinpath(directory, "env"),
        "instantiate" => options.instantiate))
    result = joinpath(directory, "result.toml")
    log = joinpath(directory, "log.txt")
    command = julia_command(joinpath(_SCRIPTS, "prepare.jl"), [request, result];
        project=dirname(tool_project()), threads=1, env=merge(Dict("JULIA_NUM_PRECOMPILE_TASKS" => "2"), env))
    process = run_worker(Cmd(command; dir=directory), log, options.timeout)
    isfile(result) || return Environment(:failed, joinpath(directory, "env"), process.timed_out ?
        "environment preparation timed out; see $log" :
        "environment preparation exited with code $(process.code); see $log")
    data = TOML.parsefile(result)
    message = data["message"]
    # Preparation writes its outcome before precompiling, which can then time out or crash.
    if data["status"] == "ready" && (process.timed_out || process.code != 0)
        ending = process.timed_out ? "timed out" : "exited with code $(process.code); see $log"
        message = strip("$message Precompilation $ending; packages without package images load from source.")
    end
    return Environment(Symbol(data["status"]), data["dir"], message)
end

"""
A context's environment and the digests of the files it was prepared from (see
`_environment_inputs`), which are checked before each of its units runs.
"""
mutable struct _Prepared
    environment::Environment
    inputs::Dict{String,String}
    preparations::Int
    const lock::ReentrantLock
end

const _METADATA_NAMES = (_PROJECT_FILES..., "Manifest.toml", "JuliaManifest.toml",
    "Manifest-v$(VERSION.major).$(VERSION.minor).toml", "JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
    "LocalPreferences.toml", "JuliaLocalPreferences.toml")

_digest(file::String) = isfile(file) ? bytes2hex(open(sha256, file)) : ""
_digests(files) = Dict{String,String}(file => _digest(file) for file in files)

"""
The files an environment is prepared from, whose edits can leave it out of date: the
project, manifest and preference files of the projects its context combines and of the
workspaces they belong to, the project files of the other members of those workspaces,
which are resolved with them, and the project files of the path dependencies that their
sources and manifests name, wherever they are. They are digested before preparation reads
them, so that an edit while it runs prepares the environment again; path dependencies that
only resolution finds are added after (see `_add_resolved_inputs!`).
"""
function _environment_inputs(context::Context)
    directories, files = String[], String[]
    for path in (context.owner, context.project, context.test && !isempty(context.owner) ? joinpath(context.owner, "test") : "")
        isempty(path) && continue
        file = _project_file(path)
        push!(directories, file === nothing ? path : dirname(file))
    end
    # Files that cannot be read now, as while they are written, fail preparation, or are
    # read by it once written; the environment's manifest then names its path dependencies.
    try
        for file in _context_files(context)
            append!(directories, dirname.(Base.get_projects_workspace_to_root(file)))
        end
        envs = _context_envs(context)
        append!(files, (joinpath(dirname(member), name) for env in envs for member in keys(env.workspace)
                        for name in _PROJECT_FILES))
        # Imports from the registry name no path dependencies; looking them up is not needed.
        imports = filter(((_, directory),) -> !isempty(directory), context.imports)
        project, _ = _scratch_project(Context(context.project, context.owner, context.test, context.triggers, imports), envs)
        for entry in values(_refresh_paths!(_seed_manifest(envs), project, envs))
            path = entry.path
            path === nothing || append!(files, joinpath.(path, _PROJECT_FILES))
        end
    catch err
        err isa InterruptException && rethrow()
    end
    return unique!([[joinpath(directory, name) for directory in unique!(directories) for name in _METADATA_NAMES]; files])
end

"Add the project files of the path dependencies of `environment`, as they are now, to `inputs` that lack them."
function _add_resolved_inputs!(inputs::Dict{String,String}, environment::Environment)
    manifest = joinpath(environment.dir, "Manifest.toml")
    ready(environment) && isfile(manifest) || return inputs
    for entry in values(Pkg.Types.read_manifest(manifest))
        path = entry.path
        path === nothing && continue
        for name in _PROJECT_FILES
            file = joinpath(abspath(environment.dir, path), name)
            get!(() -> _digest(file), inputs, file)
        end
    end
    return inputs
end

"""
The environment for the next unit of a context: the one prepared, or, if files it was
prepared from have changed since, one that `prepare_again(n)` prepares from them, for the
`n`th time. Units that ran after such an edit would otherwise load code that their
environment does not match, such as a path dependency that now imports a package its old
dependencies leave out. If preparing again fails, units keep the environment they had.
"""
function _current!(prepare_again, prepared::_Prepared, context::Context)
    @lock prepared.lock begin
        changed = sort!([file for (file, digest) in prepared.inputs if _digest(file) != digest])
        isempty(changed) && return prepared.environment
        inputs = _digests(union(keys(prepared.inputs), _environment_inputs(context)))
        environment = prepare_again(prepared.preparations += 1)
        cause = join(changed, ", ") * " changed during the run"
        if ready(environment)
            prepared.environment = Environment(:ready, environment.dir,
                                               strip("It was prepared again, since $cause. " * environment.message))
            _add_resolved_inputs!(inputs, environment)
        else
            previous = prepared.environment
            prepared.environment = Environment(previous.status, previous.dir, strip(previous.message *
                " Preparing it again, since $cause, failed: " * first(split(environment.message, '\n'))))
        end
        prepared.inputs = inputs
        return prepared.environment
    end
end

# Units
# =====

const _SCRIPTS = joinpath(dirname(@__DIR__), "scripts")

"What analyzing a unit needs from its sweep."
struct _Sweep
    inventory::Inventory
    output::String
    options::SweepOptions
    syntax::Dict{String,Syntax}
    "Test units by entry, to follow chains of test drivers."
    tests::Dict{String,Unit}
    "Files each test driver includes at run time that are analyzed as their own units."
    separate::Dict{String,Vector{String}}
    "Concretization patterns by file and the modules imported before it, since many units load the same files."
    patterns::Dict{Tuple{String,Vector{Symbol}},Vector{String}}
end

"The `.JETLSConfig.toml` a unit analyzes with: configured, or the nearest at or above its entry."
function _jetls_config(unit::Unit)
    isempty(unit.overrides.jetls_config) || return unit.overrides.jetls_config
    directory = dirname(unit.entry)
    while true
        file = joinpath(directory, ".JETLSConfig.toml")
        isfile(file) && return file
        dirname(directory) == directory && return ""
        directory = dirname(directory)
    end
end

"A path as a literal glob: JETLS matches configured paths with escapes enabled."
_glob_literal(path::AbstractString) = replace(_slash(path), r"([\\*?\[\]])" => s"\\\1")

const _PATH_SETTINGS = (("diagnostic", "patterns"), ("full_analysis", "concretization_patterns"),
                        ("initialization_options", "analysis_overrides"))

"""
Test drivers that run `unit`'s entry, outermost first: the chain of driver units, and the
nearest `runtests.jl` when the last of them includes it statically.
"""
function _drivers(unit::Unit, sweep::_Sweep)
    drivers = String[]
    driver = unit.driver
    while !isempty(driver) && !(driver in drivers)
        pushfirst!(drivers, driver)
        driver = haskey(sweep.tests, driver) ? sweep.tests[driver].driver : ""
    end
    isempty(drivers) && return drivers
    tests = joinpath(unit.context.owner, "test")
    directory = dirname(unit.entry)
    while _within(directory, tests) && directory != dirname(last(drivers))
        nearest = joinpath(directory, "runtests.jl")
        if nearest != unit.entry && haskey(sweep.tests, last(drivers)) && nearest in sweep.tests[last(drivers)].expected
            push!(drivers, nearest)
            break
        end
        directory = dirname(directory)
    end
    return drivers
end

"""
Write the unit's JETLS configuration and return its directory, and the root its paths are
relative to: the sweep root, or the directory of the user's configuration where that holds the
root. The user's configuration applies with its paths rebased from its own directory to that
root, plus the settings a sweep requires, and a batch default for `concretization_timeout`.

Script analysis also evaluates the statements of the files it loads that are free of side
effects, and those `include` and `eval` calls need (`concretization_patterns`), so that
definitions and includes depending on their values load. A test driver's unit skips
including the files it includes at run time that are analyzed as their own units.
"""
function _write_jetls_config(unit::Unit, directory::String, sweep::_Sweep, separate::Vector{String},
                             drivers::Vector{String}=String[], setups::Vector{String}=String[])
    source = _jetls_config(unit)
    root = !isempty(source) && _within(sweep.inventory.root, dirname(source)) ? dirname(source) : sweep.inventory.root
    data = isempty(source) ? Dict{String,Any}() : TOML.parsefile(source)
    prefix = isempty(source) ? "." : relpath(dirname(source), root)
    for (section, key) in _PATH_SETTINGS, entry in get(get(data, section, Dict()), key, Any[])
        prefix != "." && entry isa AbstractDict && get(entry, "path", nothing) isa String &&
            (entry["path"] = _glob_literal(prefix) * "/" * entry["path"])
    end
    full = get!(data, "full_analysis", Dict{String,Any}())
    full["auto_instantiate"] = "never"   # JETSweep prepares every environment itself
    # JETLS's 10 s per top-level statement suits an editor; it counts compilation, which
    # parallel analyses slow down, so a sweep's results would depend on its load.
    get!(full, "concretization_timeout", 300.0)
    diagnostic = get!(data, "diagnostic", Dict{String,Any}())
    diagnostic["enabled"] = true
    diagnostic["all_files"] = true
    if unit.kind in (:test, :script, :orphan)
        patterns = get!(full, "concretization_patterns", Any[])
        loaded = union((_reach(file, sweep.syntax; followed_only=true) for file in [unit.entry; unit.overrides.setup; setups])...)
        # A test file can read the modules its drivers' prelude imports.
        modules = isempty(drivers) ? Set{Symbol}() : prelude_modules(drivers, unit.entry; packages=_owner(unit, sweep.inventory))
        for file in sort!(collect(loaded))
            isfile(file) && _within(file, root) || continue
            path = _glob_literal(relpath(file, root))
            key = (file, sort!(collect(modules)))
            for pattern in get!(() -> concretization_patterns(file; modules), sweep.patterns, key)
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
    return dirname(_write_toml(joinpath(directory, "config", ".JETLSConfig.toml"), data)), root
end

"The package a unit belongs to, by name, whose `pkgdir` and `pathof` its files may name."
function _owner(unit::Unit, inventory::Inventory)
    index = findfirst(project -> project.dir == unit.context.owner, inventory.projects)
    (index === nothing || isempty(inventory.projects[index].name)) && return Dict{String,Project}()
    return Dict(inventory.projects[index].name => inventory.projects[index])
end

"""
The test files that define the ReTestItems test setups that the test items of `unit` name and
its own files do not define. ReTestItems finds a setup among the test files of the package.
"""
function _setup_files(unit::Unit, sweep::_Sweep)
    unit.kind === :test || return String[]
    files = union((_reach(file, sweep.syntax; followed_only=true) for file in [unit.entry; unit.overrides.setup])...)
    facts = [sweep.syntax[file] for file in files if haskey(sweep.syntax, file)]
    needed = setdiff(union(String[], (f.uses for f in facts)...), (setup for f in facts for setup in f.setups))
    found = String[]
    tests = joinpath(unit.context.owner, "test")
    for source in sweep.inventory.sources
        isempty(needed) && break
        source.kind === :test && _within(source.path, tests) && haskey(sweep.syntax, source.path) || continue
        defined = intersect(needed, sweep.syntax[source.path].setups)
        isempty(defined) && continue
        push!(found, source.path)
        setdiff!(needed, defined)
    end
    return found
end

"""
The entry file analyzed for a test or script unit: its context, then the original file. The
context includes the files that define the test setups its test items name.
"""
function _generated_entry(unit::Unit, drivers::Vector{String}, inventory::Inventory, setups::Vector{String}=String[])
    io = IOBuffer()
    println(io, "# Generated by JETSweep for ", unit.entry)
    println(io, "const Main = @__MODULE__")
    isempty(drivers) || print(io, prelude(drivers, unit.entry; packages=_owner(unit, inventory), setups))
    for file in [unit.overrides.setup; setups]
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

"""
The uncaught error a worker printed before it exited with `code` without a result, as
`": message"`, if any. Julia prints that error last; a signal prints none of its own, so any
error before it was caught.
"""
function _worker_error(log::String, code::Integer)
    0 < code < 128 && isfile(log) || return nothing
    message = nothing
    for line in eachline(log)
        startswith(line, "ERROR: ") && (message = ": " * chopprefix(line, "ERROR: "))
    end
    return message
end

"A unit's notes: its plan's, and its environment's."
_notes(unit::Unit, environment::Environment) =
    isempty(environment.message) ? copy(unit.notes) : [unit.notes; "environment: " * environment.message]

function _analyze(unit::Unit, environment::Environment, sweep::_Sweep, gpu::Union{Nothing,String})
    if !ready(environment)
        # The unit never runs; what preparation logged, if anything, tells why.
        preparation_log = joinpath(_environment_directory(sweep.output, unit.context), "log.txt")
        return UnitResult(unit.id, :unavailable, Finding[], String[], ["environment unavailable: " * environment.message],
                          copy(unit.notes), 0.0, filesize(preparation_log) > 0 ? preparation_log : "")
    end
    directory = joinpath(sweep.output, "units", unit.id)
    mkpath(directory)
    log = joinpath(directory, "log.txt")
    started = time()
    notes = _notes(unit, environment)
    failure(status, reason) = UnitResult(unit.id, status, Finding[], String[], [reason], copy(notes), time() - started, log)
    generated = joinpath(directory, "entry.jl")
    drivers = _drivers(unit, sweep)
    # The test items of files included for the setups they define are left to their own units.
    setups = _setup_files(unit, sweep)
    unit.kind in (:test, :script) && write(generated, _generated_entry(unit, drivers, sweep.inventory, setups))
    # A driver's own unit skips the test files it includes at run time; the units of those
    # files load only its prelude.
    separate = get(sweep.separate, unit.entry, String[])
    name, uuid = _package(unit, sweep.inventory)
    config, root = _write_jetls_config(unit, directory, sweep, separate, drivers, setups)
    # Diagnostics are judged by the configuration nearest their file, unless one is configured for the unit.
    request = _write_toml(joinpath(directory, "request.toml"), Dict(
        "kind" => String(unit.kind), "entry" => unit.entry, "environment" => environment.dir,
        "generated" => generated, "config" => config, "configured" => !isempty(unit.overrides.jetls_config),
        "root" => root, "package" => name, "uuid" => uuid, "extension" => unit.extension,
        "triggers" => unit.context.triggers, "args" => unit.overrides.args, "env" => unit.overrides.env,
        "setups" => setups))
    # A unit that runs again in an environment prepared again (see `sweep`) must not report its first result.
    result = joinpath(directory, "result.toml")
    rm(result; force=true)
    threads = unit.kind in (:package, :extension) ? sweep.options.threads : 1
    command = julia_command(joinpath(_SCRIPTS, "analyze.jl"), [request, result]; project=environment.dir,
        threads, compile=false, env=gpu === nothing ? Dict{String,String}() : Dict("CUDA_VISIBLE_DEVICES" => gpu))
    process = run_worker(Cmd(command; dir=dirname(unit.entry)), log, sweep.options.timeout)
    process.timed_out && return failure(:timeout, "time limit of $(sweep.options.timeout) s exceeded")
    isfile(result) || return failure(:failed, "worker exited with code $(process.code) without a result" *
                                     something(_worker_error(log, process.code), ""))
    data = TOML.parsefile(result)
    haskey(data, "error") && return failure(:failed, first(split(data["error"], '\n')))
    reasons = String[data["reasons"]..., ("logged error: " * error for error in data["errors"])...]
    analyzed = Vector{String}(data["analyzed"])
    # Files the analysis did not reach are analyzed by follow-up units; see `_followups`.
    missed = setdiff(unit.expected, analyzed)
    isempty(missed) || push!(notes, "not reached by this analysis: " * join(_display.(missed, sweep.inventory.root), ", "))
    found = [Finding(row["file"], row["line"], row["column"], row["end_line"], row["end_column"],
                     row["severity"], row["code"], row["message"]) for row in data["findings"]]
    status = !isempty(reasons) ? :incomplete : isempty(found) ? :clean : :findings
    return UnitResult(unit.id, status, found, analyzed, reasons, notes, time() - started, log)
end

"""
Units for the files a unit expected to cover but did not reach. Package and extension files
that loading left out, such as conditionally included code, become orphan units analyzed
in the parent's module. Files a test or script did not reach, after an analysis stop say,
are analyzed from themselves in the same context. Either way, a missed file that includes
other missed files covers them.
"""
function _followups(unit::Unit, result::UnitResult, sweep::_Sweep, planned::Set{String})
    result.status in (:clean, :findings, :incomplete) && !isempty(result.analyzed) || return Unit[]
    missed = setdiff(unit.expected, result.analyzed, planned)
    # A file included inside a module block other than its package's own module belongs to
    # that module, which a follow-up cannot recreate; it stays uncovered.
    package = unit.kind in (:package, :extension)
    for file in unit.expected, include in get(sweep.syntax, file, Syntax(Include[], String[])).includes
        include.depth > (package && file == unit.entry) && setdiff!(missed, [include.target])
    end
    # A JLL package's wrappers for other platforms need its module's identity; they are not
    # analyzed by themselves either.
    name, _ = _package(unit, sweep.inventory)
    endswith(name, "_jll") && filter!(file -> !_within(file, joinpath(unit.context.owner, "src", "wrappers")), missed)
    isempty(missed) && return Unit[]
    root = sweep.inventory.root
    groups = _entries(missed, sweep.syntax)
    if unit.kind in (:package, :extension, :orphan)
        overrides = Overrides(; args=unit.overrides.args, env=unit.overrides.env, jetls_config=unit.overrides.jetls_config)
        return [Unit(_unit_id(:orphan, entry, root, unit.extension), :orphan, entry, unit.context, expected, "",
                     unit.extension, overrides, ["not included when its package loaded"]) for (entry, expected) in groups]
    end
    driver = unit.kind === :test && basename(unit.entry) == "runtests.jl" ? unit.entry : unit.driver
    return [Unit(_unit_id(unit.kind, entry, root), unit.kind, entry, unit.context, expected, driver, "",
                 unit.overrides, ["not reached when analyzing $(_display(unit.entry, root))"]) for (entry, expected) in groups]
end

"""
Seconds each unit took in the latest report below `root/.jetsweep`, if this version of
JETSweep wrote it, for units whose analysis ran. Unit ids are stable across runs, so a
repeated sweep can start its longest analyses first.
"""
function _previous_seconds(root::String)
    directory = joinpath(root, ".jetsweep")
    reports = isdir(directory) ? filter(isfile, joinpath.(readdir(directory; join=true), "report.toml")) : String[]
    isempty(reports) && return Dict{String,Float64}()
    try
        report = TOML.parsefile(argmax(mtime, reports))
        report["jetsweep"] == string(pkgversion(@__MODULE__)) || return Dict{String,Float64}()
        return Dict{String,Float64}(r["unit"] => r["seconds"] for r in report["results"]
                                    if r["status"] in ("clean", "findings", "incomplete", "timeout"))
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
# longest analyses. A unit takes one slot: package analyses run signature analysis on
# several threads, but use little more than one core on average.
_task(context::Context, units, previous) =
    _Task(2, (0, -round(Int, sum(unit -> _cost(unit, previous), units; init=0.0))), context)
_task(unit::Unit, previous) = _Task(1, (1, -round(Int, _cost(unit, previous))), unit)

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
Create the directory `name` in `parent`, or `name-2`, `name-3` and so on if it exists. Only
one `mkdir` of a path succeeds, so sweeps started in the same second get their own.
"""
function _new_directory(parent::String, name::String)
    mkpath(parent)
    for n in Iterators.countfrom(1)
        try
            return mkdir(joinpath(parent, n == 1 ? name : "$name-$n"))
        catch err
            err isa Base.IOError && err.code == Base.UV_EEXIST || rethrow()
        end
    end
end

"""
Notes on the `[[context]]` tables that select no planned unit, as is expected of a sweep that
leaves out the files they select: with `--exclude`, or of a directory below the
configuration's. A table that selects no unit of the full sweep either, of the configuration's
directory without `--exclude`, is a mistake.
"""
function _unselected(config::Config, units::Vector{Unit}, root::String, options::SweepOptions, output::String)
    unselected = filter(rule -> !any(unit -> _selects(rule, config, unit.entry), units), config.contexts)
    isempty(unselected) && return String[]
    full = config.directory == root && isempty(options.exclude) ? units :
        plan(discover(config.directory; config, output, include_ignored=options.include_ignored,
                      tracked_only=options.tracked_only))
    for rule in unselected
        any(unit -> _selects(rule, config, unit.entry), full) ||
            throw(ArgumentError("$(config.file): [[context]] match $(repr(rule.match)) selects no unit"))
    end
    return ["$(config.file): [[context]] match $(repr(rule.match)) selects no unit of this sweep, " *
            "which leaves out the files it selects" for rule in unselected]
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
    # Every environment needs the analyzer; a plan needs none.
    options.plan_only || _require_tool()
    started = time()
    root = realpath(root)
    config = read_config(root, options.config)
    requested = isempty(options.output) ? "" : abspath(options.output)
    isempty(requested) || !ispath(requested) || isdir(requested) && isempty(readdir(requested)) ||
        throw(ArgumentError("report directory must be new or empty: $requested"))
    inventory = discover(root; exclude=options.exclude, config, output=requested,
                         include_ignored=options.include_ignored, tracked_only=options.tracked_only)
    syntax = source_syntax(inventory)
    units = plan(inventory, config; syntax)
    notes = _unselected(config, units, root, options, requested)
    output = isempty(requested) ? _new_directory(joinpath(root, ".jetsweep"), Libc.strftime("%Y%m%d-%H%M%S", time())) :
             mkpath(requested)
    write_tag(output)
    write_inventory(joinpath(output, "inventory.toml"), inventory)
    write_plan(joinpath(output, "plan.toml"), units, inventory.root, notes)
    contexts = unique(unit.context for unit in units)
    packages = count(ispackage, inventory.projects)
    println(io, "JETSweep: $(length(inventory.sources)) files, $packages packages, $(length(units)) units, ",
            "$(length(contexts)) environments")
    if options.plan_only
        report_issues(io, inventory, notes)
        println(io, "Plan written to $output")
        return SweepResult(root, output, inventory, units, notes, UnitResult[], String[], time() - started,
                           isempty(inventory.issues) ? 0 : 2)
    end
    before = _snapshot(inventory, config)
    gpus = _gpus(options.gpus)
    previous = _previous_seconds(root)
    members = Dict(context => filter(unit -> unit.context == context, units) for context in contexts)
    separate = Dict{String,Vector{String}}()
    foreach(unit -> isempty(unit.driver) || push!(get!(separate, unit.driver, String[]), unit.entry), units)
    state = _Sweep(inventory, output, options, syntax, Dict(unit.entry => unit for unit in units if unit.kind === :test),
                   separate, Dict{Tuple{String,Vector{Symbol}},Vector{String}}())
    environments = Dict{Context,_Prepared}()
    results = Dict{String,UnitResult}()
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
    prepared(context, directory) = contained(() -> _prepare(context, directory, options),
                                             message -> Environment(:failed, directory, message))
    # Checking inputs that are being written can fail; the unit then keeps the environment.
    current(context) = contained(_ -> environments[context].environment) do
        _current!(environments[context], context) do n
            prepared(context, "$(_environment_directory(output, context))-$n")
        end
    end
    function step(task::_Task)
        work = task.work
        if work isa Context
            # What the environment is prepared from, digested before preparation reads it.
            inputs = contained(() -> _digests(_environment_inputs(work)), _ -> Dict{String,String}())
            let environment = prepared(work, _environment_directory(output, work))
                contained(() -> _add_resolved_inputs!(inputs, environment), _ -> inputs)
                environments[work] = _Prepared(environment, inputs, 1, ReentrantLock())
            end
            return [_task(unit, previous) for unit in members[work]]
        end
        gpu = isempty(gpus) ? nothing : gpus[mod1(started_units[] += 1, length(gpus))]
        analyzed(environment) = contained(() -> _analyze(work, environment, state, gpu),
                                          message -> UnitResult(work.id, :failed, Finding[], String[], [message],
                                                                _notes(work, environment), 0.0, ""))
        environment = current(work.context)
        outcome = analyzed(environment)
        # A unit that did not complete while its environment's inputs changed runs once more, in
        # an environment prepared from them; one that ran out of time does not.
        if !complete(outcome) && outcome.status !== :timeout
            again = current(work.context)
            again.dir == environment.dir || (outcome = analyzed(again))
        end
        results[work.id] = outcome
        report_progress(io, work, outcome, length(results), length(units), root)
        followups = _followups(work, outcome, state, planned)
        for unit in followups
            union!(planned, unit.expected)
            push!(units, unit)
        end
        return [_task(unit, previous) for unit in followups]
    end
    _dispatch(step, [_task(context, members[context], previous) for context in contexts], options.jobs)
    after = _snapshot(discover(root; exclude=options.exclude, config, output,
                               include_ignored=options.include_ignored, tracked_only=options.tracked_only), config)
    changed = sort!([file for file in union(keys(before), keys(after)) if get(before, file, "") != get(after, file, "")])
    ordered = [results[unit.id] for unit in units]
    summary = SweepResult(root, output, inventory, units, notes, ordered, changed, time() - started,
                          exit_code(inventory, ordered, changed, options.fail_on))
    write_report(summary; io)
    return summary
end
