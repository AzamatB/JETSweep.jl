# Execution: scheduling, worker processes, exit codes, the command line, JETLS settings and reports.
@testsetup module Execution
using JETSweep, TOML, Test

execution_context(name) = JETSweep.Context("/execution/$name", "", false, Dict{String,String}())

execution_task(name, weight=1, priority=(0, 0)) = JETSweep._Task(weight, priority, execution_context(name))

"No cap on the slots of the process (`JETSweep.worker_cap`): the dispatch tests check a dispatch's own capacity."
execution_uncapped() = typemax(Int)

execution_name(task) = basename((task.work::JETSweep.Context).project)

"Dispatch `tasks`, recording start and end events and the peak clamped weight in use."
function execution_trace(tasks, capacity; followups=Dict{String,Vector{JETSweep._Task}}(), pause=0.02,
                         cap=execution_uncapped)
    load, peak, events = Ref(0), Ref(0), String[]
    dispatcher = @async JETSweep._dispatch(tasks, capacity; cap) do task
        name, weight = execution_name(task), min(task.weight, capacity)
        load[] += weight
        peak[] = max(peak[], load[])
        push!(events, "start $name")
        sleep(pause)
        push!(events, "end $name")
        load[] -= weight
        return get(followups, name, JETSweep._Task[])
    end
    # A scheduling bug can leave the dispatcher waiting forever.
    timedwait(() -> istaskdone(dispatcher), 60.0; pollint=0.01) === :ok || error("dispatch did not finish")
    wait(dispatcher)
    return (; peak=peak[], events, starts=[event[7:end] for event in events if startswith(event, "start ")])
end

function execution_alive(pid::Integer)
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 || return false
    Sys.islinux() || return true
    # A killed orphan may briefly wait for its new parent to reap it.
    stat = try
        read("/proc/$pid/stat", String)
    catch
        return false
    end
    return split(stat[something(findlast(')', stat))+1:end])[1] != "Z"
end

execution_sh(script, args...) = Cmd(["/bin/sh", "-c", script, "sh", args...])

function execution_gone(pid::Integer)
    timedwait(() -> !execution_alive(pid), 5.0; pollint=0.05)
    gone = !execution_alive(pid)
    gone || ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL)
    return gone
end

execution_finding(severity; file="/root/a.jl", line=1, code="code", message="message") =
    JETSweep.Finding(file, line, 1, line, 5, severity, code, message)

execution_result(status, findings=JETSweep.Finding[]) =
    JETSweep.UnitResult("unit", status, findings, String[], String[], String[], 0.0, "")

execution_inventory(issues=String[]) =
    JETSweep.Inventory("/root", JETSweep.Project[], JETSweep.Source[], [JETSweep.Project[], JETSweep.Project[]], String[], issues)

"Call `f` with standard output and error redirected; return its value and both outputs."
function execution_capture(f)
    mktempdir() do directory
        out, err = joinpath(directory, "out"), joinpath(directory, "err")
        value = open(out, "w") do outio
            open(errio -> redirect_stderr(() -> redirect_stdout(f, outio), errio), err, "w")
        end
        return value, read(out, String), read(err, String)
    end
end

"The directory of the JETSweep package under test."
const EXECUTION_PACKAGE = pkgdir(JETSweep)::String

execution_unit(entry; kind=:test, expected=[entry], setup=String[], jetls_config="") =
    JETSweep.Unit("$kind-unit", kind, entry, execution_context("unit"), expected, "", "",
                  JETSweep.Overrides(; setup, jetls_config), String[])

"A sweep of `root` in which `unit`'s entry statically includes its other expected files."
function execution_sweep(unit, root, output)
    inventory = JETSweep.Inventory(root, JETSweep.Project[], JETSweep.Source[], [JETSweep.Project[], JETSweep.Project[]], String[], String[])
    dynamic = isfile(unit.entry) ? filter(i -> isempty(i.target), JETSweep.parse_source(unit.entry).includes) : JETSweep.Include[]
    includes = [dynamic; [JETSweep.Include(file, 1, true) for file in unit.expected if file != unit.entry]]
    syntax = Dict(unit.entry => JETSweep.Syntax(includes, String[]))
    return JETSweep._Sweep(inventory, output, SweepOptions(), syntax, Dict{String,JETSweep.Unit}(),
                           Dict{String,Vector{String}}(), Dict{Tuple{String,Vector{Symbol}},Vector{String}}())
end

"Write `unit`'s JETLS configuration; returns the root its paths are relative to and the configuration."
function execution_jetls(unit, root, separate=String[])
    directory = mktempdir()
    config = JETSweep._write_jetls_config(unit, directory, execution_sweep(unit, root, directory), separate)
    @test config == joinpath(directory, "config")
    return root, TOML.parsefile(joinpath(config, ".JETLSConfig.toml"))
end

execution_touch(path, content="nothing\n") = (mkpath(dirname(path)); write(path, content); path)

"Concretization patterns of a written configuration, as (pattern, path) pairs."
execution_patterns(data) =
    [(p["pattern"], get(p, "path", "")) for p in get(data["full_analysis"], "concretization_patterns", [])]

execution_skips(data) = get(get(data, "initialization_options", Dict()), "analysis_overrides", [])

execution_skip(path) = Dict("path" => path, "on_include" => "skip")

"A test driver that includes the test files it selects at run time."
const EXECUTION_DRIVER = """
    const DIR = @__DIR__
    seed = rand()
    files = filter(file -> startswith(file, "test_"), readdir(DIR))
    for file in files
        include(joinpath(DIR, file))
    end
    """

const EXECUTION_SELECTION = "files = filter(file -> startswith(file, \"test_\"), readdir(DIR))"

const EXECUTION_USER_JETLS = """
    [full_analysis]
    debounce = 2.0
    auto_instantiate = "always"
    concretization_timeout = 30

    [[full_analysis.concretization_patterns]]
    pattern = "const C_ = v_"

    [diagnostic]
    enabled = false
    all_files = false

    [[diagnostic.patterns]]
    pattern = "lowering/unused-argument"
    match_by = "code"
    match_type = "literal"
    severity = "off"

    [[initialization_options.analysis_overrides]]
    path = "src/generated.jl"
    on_include = "skip"
    """

# JETLS's vendored Glob, with which it reads configured paths as patterns.
const EXECUTION_GLOB = Base.require(Base.PkgId(Base.UUID("a6ef924f-2b2c-5d99-b812-8edbc1441234"), "Glob"))

"Files among `files` that a configured glob in `paths` selects, matched as JETLS does."
execution_selected(paths, files, base) = filter(files) do file
    candidate = JETSweep._within(file, base) ? JETSweep._slash(relpath(file, base)) : file
    any(path -> occursin(EXECUTION_GLOB.FilenameMatch(path, "dp"), candidate), paths)
end

"Files in which JETLS concretizes `statement`: those its patterns select below the root."
function execution_concretized(data, statement, files, base)
    paths = [path for (pattern, path) in execution_patterns(data) if pattern == statement]
    return filter(file -> JETSweep._within(file, base), execution_selected(paths, files, base))
end

execution_skipped(data, files, base) =
    execution_selected([override["path"] for override in execution_skips(data)], files, base)

execution_script(name) = JETSweep.Unit("script-$name", :script, "/root/$name.jl", execution_context(name),
                                       ["/root/$name.jl"], "", "", JETSweep.Overrides(), String[])

execution_incomplete(name, status, reasons, notes=String[]; log="") =
    JETSweep.UnitResult("script-$name", status, JETSweep.Finding[], String[], reasons, notes, 1.0, log)

"Report a sweep of `/root` with these units and results; return the terminal summary and summary.txt."
function execution_report(output, units, results)
    inventory = JETSweep.Inventory("/root", JETSweep.Project[], JETSweep.Source[], [JETSweep.Project[], JETSweep.Project[]], String[], String[])
    io = IOBuffer()
    JETSweep.write_report(JETSweep.SweepResult("/root", output, inventory, units, String[], results, String[], 1.0, 2); io)
    return String(take!(io)), read(joinpath(output, "summary.txt"), String)
end

export TOML, execution_context, execution_task, execution_uncapped, execution_name, execution_trace, execution_alive,
    execution_sh, execution_gone, execution_finding, execution_result, execution_inventory, execution_capture,
    EXECUTION_PACKAGE, execution_unit, execution_sweep, execution_jetls, execution_touch, execution_patterns,
    execution_skips, execution_skip, EXECUTION_DRIVER, EXECUTION_SELECTION, EXECUTION_USER_JETLS, EXECUTION_GLOB,
    execution_selected, execution_concretized, execution_skipped, execution_script, execution_incomplete,
    execution_report
end

@testitem "Dispatch runs every task once, in priority order, within capacity" setup=[Execution] begin
    trace = execution_trace(JETSweep._Task[], 3)
    @test isempty(trace.events)
    weights = [3, 1, 2, 2, 1, 4, 1, 1, 2, 3, 1, 2]
    priorities = [(i % 3, (7i) % 11) for i in eachindex(weights)]
    tasks = [execution_task("t$i", weights[i], priorities[i]) for i in eachindex(weights)]
    for capacity in (1, 3, 4)
        trace = execution_trace(tasks, capacity)
        @test sort(trace.starts) == sort(["t$i" for i in eachindex(weights)])
        @test allunique(trace.starts)
        @test trace.starts == ["t$i" for i in sortperm(priorities)]
        @test trace.peak <= capacity
    end
    @test execution_trace([execution_task("u$i") for i in 1:8], 4).peak == 4
end

# The cap of what a process runs at once, which JETSweep takes from the machine: GitHub's runner and this machine.
@testitem "A process's slots are capped by its CPU threads and free memory" setup=[Execution] begin
    GB = 1000^3
    # This suite's CI runner, GitHub's ubuntu-latest: 4 vCPUs and 16 GB, of which the system holds about 1 GB and the
    # suite's test processes 3.2 GB when its sweeps start. The sweeps' analysis workers take about 0.85 GB each.
    runner = JETSweep.worker_cap(4, 16GB - 1GB - 32GB ÷ 10)
    @test runner == 3   # not 4: the free memory, at 3 GiB a slot, sets it
    @test runner * 85GB ÷ 100 + 32GB ÷ 10 + 1GB <= 16GB
    # An 8-vCPU slot of this machine (JULIA_CPU_THREADS=8), with hundreds of GB free, or with the 64 GB of the
    # g6e.2xlarge it emulates: every vCPU.
    @test JETSweep.worker_cap(8, 300GB) == 8
    @test JETSweep.worker_cap(8, 64GB - 1GB - 32GB ÷ 10) == 8
    @test JETSweep.worker_cap(48, 7 * 1024^3) == 2
    @test JETSweep.worker_cap(8, 0) == JETSweep.worker_cap(0, 300GB) == 1   # at least one
    @test 1 <= JETSweep.worker_cap() <= Sys.CPU_THREADS
    @test SweepOptions().jobs == Sys.CPU_THREADS   # (the cap applies whatever `jobs` asks)
end

@testitem "Dispatches side by side share the process's slots" setup=[Execution] begin
    load, peak, ran = Ref(0), Ref(0), String[]
    loads, peaks = Dict(name => Ref(0) for name in ("a", "b")), Dict(name => Ref(0) for name in ("a", "b"))
    # (A dispatch that an earlier item interrupted may still be releasing its slots.)
    timedwait(() -> JETSweep._SHARED.used[] == 0, 60.0; pollint=0.01)
    # Each dispatch asks for 3 slots, of the 4 the process has.
    dispatch(name) = JETSweep._dispatch([execution_task("$name$i") for i in 1:6], 3; cap=() -> 4) do task
        push!(ran, execution_name(task))
        load[] += 1
        loads[name][] += 1
        peak[] = max(peak[], load[])
        peaks[name][] = max(peaks[name][], loads[name][])
        sleep(0.05)
        load[] -= 1
        loads[name][] -= 1
        return JETSweep._Task[]
    end
    dispatches = [@async(dispatch(name)) for name in ("a", "b")]
    timedwait(() -> all(istaskdone, dispatches), 60.0; pollint=0.01) === :ok || error("dispatch did not finish")
    foreach(wait, dispatches)
    @test sort(ran) == sort(["$name$i" for name in ("a", "b") for i in 1:6])
    @test peak[] == 4
    @test peaks["a"][] <= 3 && peaks["b"][] <= 3
    @test JETSweep._SHARED.used[] == 0
    # A task heavier than the process's slots is clamped to them and runs alone.
    trace = execution_trace([execution_task("L", 1, (0, 1)), execution_task("H", 5, (0, 0))], 8; cap=() -> 2)
    @test trace.events == ["start H", "end H", "start L", "end L"]
end

@testitem "A task that does not fit blocks later tasks" setup=[Execution] begin
    tasks = [execution_task("C", 1, (0, 2)), execution_task("A", 2, (0, 0)), execution_task("B", 2, (0, 1))]
    trace = execution_trace(tasks, 3)
    @test trace.starts == ["A", "B", "C"]
    @test findfirst(==("start C"), trace.events) > findfirst(==("end A"), trace.events)
    @test trace.peak == 3
end

@testitem "Weight above capacity is clamped and runs alone" setup=[Execution] begin
    trace = execution_trace([execution_task("L", 1, (0, 1)), execution_task("H", 10, (0, 0))], 2)
    @test trace.events == ["start H", "end H", "start L", "end L"]
    @test trace.peak == 2
    @test execution_trace([execution_task("H", 100)], 1).events == ["start H", "end H"]
end

@testitem "Follow-up tasks are scheduled by priority" setup=[Execution] begin
    tasks = [execution_task("A", 1, (0, 0)), execution_task("B", 1, (2, 0)), execution_task("C", 1, (0, 1))]
    followups = Dict("A" => [execution_task("F", 1, (1, 0)), execution_task("E", 1, (0, -5))],
                     "F" => [execution_task("G", 1, (3, 0))])
    @test execution_trace(tasks, 1; followups).starts == ["A", "E", "C", "F", "B", "G"]
    trace = execution_trace(tasks, 2; followups)
    @test sort(trace.starts) == ["A", "B", "C", "E", "F", "G"]
    @test trace.peak <= 2
end

@testitem "A failing step stops new tasks and propagates once running tasks finish" setup=[Execution] begin
    events, failed = String[], Base.Event()
    tasks = [execution_task("slow", 1, (0, 0)), execution_task("bad", 1, (0, 1)),
             (execution_task("rest$i", 1, (1, i)) for i in 1:3)...]
    failure = try
        JETSweep._dispatch(tasks, 2; cap=execution_uncapped) do task
            name = execution_name(task)
            push!(events, "start $name")
            name == "bad" && (notify(failed); error("step failed"))
            if name == "slow"
                wait(failed)
                sleep(0.2)
                push!(events, "end slow")
                return [execution_task("followup", 1, (0, 0))]
            end
            return JETSweep._Task[]
        end
        nothing
    catch err
        err
    end
    @test failure isa CapturedException
    @test failure.ex == ErrorException("step failed")
    @test events == ["start slow", "start bad", "end slow"]
end

@testitem "An interrupt stops every running worker at once" setup=[Execution] begin
    mktempdir() do directory
        started = time()
        tasks = [execution_task("w$i", 1, (0, i)) for i in 1:3]
        failure = try
            JETSweep._dispatch(tasks, 3; cap=execution_uncapped) do task
                name = execution_name(task)
                name == "w3" && (sleep(1.0); throw(InterruptException()))
                JETSweep.run_worker(execution_sh("echo \$\$ > \"\$1\"; exec sleep 60", joinpath(directory, name)),
                                    joinpath(directory, "log"), 0.0)
                return JETSweep._Task[]
            end
            nothing
        catch err
            err
        end
        @test failure isa InterruptException
        @test time() - started < 15
        @test all(name -> execution_gone(parse(Int, readchomp(joinpath(directory, name)))), ["w1", "w2"])
    end
end

@testitem "Worker exit codes, signals and logs" setup=[Execution] begin
    mktempdir() do directory
        log = joinpath(directory, "worker.log")
        write(log, "previous\n")
        @test JETSweep.run_worker(execution_sh("echo out; echo err >&2; exit 7"), log, 30.0) ==
              (code=7, timed_out=false)
        @test JETSweep.run_worker(execution_sh("echo again"), log, 30.0) == (code=0, timed_out=false)
        @test read(log, String) == "previous\nout\nerr\nagain\n"
        @test JETSweep.run_worker(execution_sh("kill -TERM \$\$"), log, 30.0) ==
              (code=128 + Base.SIGTERM, timed_out=false)
        @test JETSweep.run_worker(execution_sh("kill -KILL \$\$"), log, 30.0) ==
              (code=128 + Base.SIGKILL, timed_out=false)
        @test JETSweep.run_worker(execution_sh("sleep 0.5; exit 3"), log, 0.0) == (code=3, timed_out=false)
        @test isempty(JETSweep._ACTIVE)
    end
end

@testitem "Worker process groups are terminated" setup=[Execution] begin
    mktempdir() do directory
        log = joinpath(directory, "worker.log")
        pidfile = joinpath(directory, "child.pid")
        started = time()
        result = JETSweep.run_worker(execution_sh("sleep 60 & echo \$! > \"\$1\"; sleep 60", pidfile), log, 1.0)
        @test result == (code=128 + Base.SIGTERM, timed_out=true)
        @test time() - started < 15
        @test execution_gone(parse(Int, readchomp(pidfile)))
        rm(pidfile)
        started = time()
        result = JETSweep.run_worker(execution_sh("sleep 60 & echo \$! > \"\$1\"", pidfile), log, 60.0)
        @test result == (code=0, timed_out=false)
        @test time() - started < 15
        @test execution_gone(parse(Int, readchomp(pidfile)))
        started = time()
        result = JETSweep.run_worker(execution_sh("trap '' TERM; sleep 60"), log, 0.5)
        @test result == (code=128 + Base.SIGKILL, timed_out=true)
        @test 5 <= time() - started < 20
        @test isempty(JETSweep._ACTIVE)
    end
end

@testitem "Workers get a virtual display when there is none" setup=[Execution] begin
    if Sys.islinux() && Sys.which("Xvfb") !== nothing
        withenv("DISPLAY" => nothing) do
            # Workers get the display; this process's environment stays as it was.
            command, environment = JETSweep.with_display() do
                JETSweep.julia_command("/scripts/worker.jl", String[]; project="/environment", threads=1), copy(ENV)
            end
            @test any(variable -> occursin(r"^DISPLAY=:\d+$", variable), command.env)
            @test !haskey(environment, "DISPLAY") && isempty(JETSweep._DISPLAY[])
        end
        @test withenv(() -> JETSweep.with_display(() -> JETSweep._DISPLAY[]), "DISPLAY" => ":7") == ""
    end
end

@testitem "Worker Julia command" setup=[Execution] begin
    command = withenv("JULIA_PROJECT" => "/elsewhere", "JULIA_LOAD_PATH" => "/elsewhere",
                      "OMP_NUM_THREADS" => "8", "JETSWEEP_EXECUTION_MARK" => "inherited") do
        JETSweep.julia_command("/scripts/worker.jl", ["a", "b c"]; project="/environment", threads=3,
                               env=Dict("JULIA_NUM_PRECOMPILE_TASKS" => "2", "EXTRA" => "x"))
    end
    variables = Dict(Pair(split(entry, '='; limit=2)...) for entry in command.env)
    @test variables["JULIA_LOAD_PATH"] == "@:@stdlib"
    @test !haskey(variables, "JULIA_PROJECT")
    @test variables["JETSWEEP_EXECUTION_MARK"] == "inherited"
    @test variables["JULIA_NUM_PRECOMPILE_TASKS"] == "2"
    @test variables["EXTRA"] == "x"
    @test variables["JULIA_PKG_PRECOMPILE_AUTO"] == "0"
    @test variables["OMP_NUM_THREADS"] == variables["OPENBLAS_NUM_THREADS"] == "1"
    # No code generation flags of this process, such as `--check-bounds=yes`.
    @test command.exec == [joinpath(Sys.BINDIR, Base.julia_exename()), "--startup-file=no", "--history-file=no",
                           "--compiled-modules=yes", "--threads=3,0", "--project=/environment",
                           "/scripts/worker.jl", "a", "b c"]
    cached = JETSweep.julia_command("/scripts/worker.jl", String[]; project="/environment", threads=1,
                                    compile=false)
    @test "--compiled-modules=existing" in cached.exec && "--threads=1,0" in cached.exec
    mktempdir() do directory
        script = joinpath(directory, "probe.jl")
        write(script, """
            println(Threads.nthreads(:default), " ", Threads.nthreads(:interactive))
            println(join(LOAD_PATH, ':'))
            println(get(ENV, "JULIA_PROJECT", "unset"))
            println(join(ARGS, '|'))
            println(Base.JLOptions().check_bounds)
            """)
        probe = withenv("JULIA_PROJECT" => directory) do
            JETSweep.julia_command(script, ["x", "y z"]; project=directory, threads=2)
        end
        log = joinpath(directory, "probe.log")
        @test JETSweep.run_worker(probe, log, 300.0) == (code=0, timed_out=false)
        # Default code generation (check_bounds 0) even when this process runs `--check-bounds=yes`.
        @test readlines(log) == ["2 0", "@:@stdlib", "unset", "x|y z", "0"]
    end
end

@testitem "Exit codes" setup=[Execution] begin
    inventory = execution_inventory()
    clean = execution_result(:clean)
    for fail_on in (:error, :warning, :info, :hint, :none)
        @test JETSweep.exit_code(inventory, JETSweep.UnitResult[], String[], fail_on) == 0
        @test JETSweep.exit_code(inventory, [clean], String[], fail_on) == 0
        issues = execution_inventory(["unreadable Project.toml"])
        @test JETSweep.exit_code(issues, [clean], String[], fail_on) == 2
        @test JETSweep.exit_code(inventory, [clean], ["/root/a.jl"], fail_on) == 2
        for status in (:incomplete, :timeout, :failed, :unavailable)
            @test JETSweep.exit_code(inventory, [clean, execution_result(status)], String[], fail_on) == 2
        end
    end
    thresholds = Dict(:error => 1, :warning => 2, :info => 3, :hint => 4, :none => 0)
    for severity in 1:4, (fail_on, threshold) in thresholds
        results = [clean, execution_result(:findings, [execution_finding(severity)])]
        @test JETSweep.exit_code(inventory, results, String[], fail_on) == (severity <= threshold ? 1 : 0)
        @test JETSweep.exit_code(inventory, [results; execution_result(:timeout)], String[], fail_on) == 2
    end
    mixed = execution_result(:findings, [execution_finding(4), execution_finding(2; line=3)])
    @test JETSweep.exit_code(inventory, [mixed], String[], :warning) == 1
    @test JETSweep.exit_code(inventory, [mixed], String[], :error) == 0
end

@testitem "Unique findings" setup=[Execution] begin
    @test JETSweep.unique_findings(JETSweep.UnitResult[]) == JETSweep.Finding[]
    @test JETSweep.unique_findings(JETSweep.UnitResult[]) isa Vector{JETSweep.Finding}
    shared = execution_finding(2; file="/root/b.jl", line=4, message=string("dup", "licate"))
    first_findings = [execution_finding(1; file="/root/b.jl", line=10), shared,
                      execution_finding(3; file="/root/a.jl", line=7, code="z")]
    second_findings = [execution_finding(2; file="/root/b.jl", line=4, message="duplicate"),
                       execution_finding(3; file="/root/a.jl", line=7, code="a"),
                       execution_finding(4; file="/root/b.jl", line=4, message="another")]
    results = [execution_result(:findings, copy(first_findings)),
               execution_result(:findings, copy(second_findings))]
    findings = JETSweep.unique_findings(results)
    key(f) = (f.file, f.line, f.code, f.message)
    @test key.(findings) == [("/root/a.jl", 7, "a", "message"), ("/root/a.jl", 7, "z", "message"),
                             ("/root/b.jl", 4, "code", "another"), ("/root/b.jl", 4, "code", "duplicate"),
                             ("/root/b.jl", 10, "code", "message")]
    @test results[1].findings == first_findings && results[2].findings == second_findings
    one = execution_result(:findings, [execution_finding(2; line=2), execution_finding(1; line=1)])
    @test JETSweep.unique_findings([one]) == [execution_finding(1; line=1), execution_finding(2; line=2)]
    @test one.findings == [execution_finding(2; line=2), execution_finding(1; line=1)]
    columns = [JETSweep.Finding("/root/a.jl", 1, column, 1, 9, 1, "code", "message") for column in (5, 2)]
    @test [f.column for f in JETSweep.unique_findings([execution_result(:findings, columns)])] == [2, 5]
    severities = execution_result(:findings, [execution_finding(1), execution_finding(2)])
    @test length(JETSweep.unique_findings([severities])) == 2
end

@testitem "Command-line arguments" setup=[Execution] begin
    directory, options = JETSweep.parse_arguments(["--jobs", "3", "--threads=2", "--timeout", "1.5",
        "--gpus", "0, 2", "--output", "out", "--config=jetsweep.toml", "--exclude", "a/**", "--exclude=b=c",
        "--include-ignored", "--tracked-only", "--offline", "--plan", "--fail-on", "warning", "workspace"])
    @test directory == "workspace"
    @test options.jobs == 3
    @test options.threads == 2
    @test options.timeout == 1.5
    @test options.gpus == ["0", "2"]
    @test options.output == abspath("out")
    @test options.config == abspath("jetsweep.toml")
    @test options.exclude == ["a/**", "b=c"]
    @test options.include_ignored && options.tracked_only && options.plan_only
    @test !options.instantiate
    @test options.fail_on === :warning
    directory, parsed = JETSweep.parse_arguments(["workspace"])
    @test directory == "workspace"
    defaults = SweepOptions()
    @test all(name -> getfield(parsed, name) == getfield(defaults, name), fieldnames(SweepOptions))
    @test JETSweep.parse_arguments(["--gpus=none", "workspace"])[2].gpus == ["none"]
    options = JETSweep.parse_arguments(["--fail-on=none", "--timeout=0", "workspace"])[2]
    @test options.fail_on === :none && options.timeout === 0.0
    directory, options = JETSweep.parse_arguments(["--plan", "--", "--jobs"])
    @test directory == "--jobs" && options.plan_only && options.jobs == defaults.jobs
    @test JETSweep.parse_arguments(["workspace", "--"])[1] == "workspace"
    @test JETSweep.parse_arguments(["--", "-x"])[1] == "-x"
    for (arguments, message) in (
            (String[], "give exactly one directory; see `jetsweep --help`"),
            (["a", "b"], "give exactly one directory; see `jetsweep --help`"),
            (["--", "a", "b"], "give exactly one directory; see `jetsweep --help`"),
            (["a", "--", "b"], "give exactly one directory; see `jetsweep --help`"),
            (["--plan"], "give exactly one directory; see `jetsweep --help`"),
            (["--unknown", "a"], "unknown option --unknown"),
            (["--unknown=1", "a"], "unknown option --unknown"),
            (["-j", "4", "a"], "unknown option -j"),
            (["--plan=yes", "a"], "unknown option --plan"),
            (["a", "--jobs"], "--jobs needs a value"),
            (["--jobs=", "a"], "--jobs needs a value"),
            (["a", "--exclude"], "--exclude needs a value"),
            (["--output=", "a"], "--output needs a value"),
            (["--jobs=2", "--jobs", "3", "a"], "--jobs given more than once"),
            (["--output", "x", "--output=y", "a"], "--output given more than once"),
            (["--fail-on", "error", "--fail-on=hint", "a"], "--fail-on given more than once"),
            (["--gpus", "0", "--gpus", "1", "a"], "--gpus given more than once"))
        @test_throws ArgumentError(message) JETSweep.parse_arguments(arguments)
    end
    # A value that is not a number names its option.
    for (arguments, message) in (
            (["--jobs", "many", "a"], "--jobs needs an integer, not \"many\""),
            (["--jobs=1.5", "a"], "--jobs needs an integer, not \"1.5\""),
            (["--jobs", "99999999999999999999", "a"], "--jobs needs an integer, not \"99999999999999999999\""),
            (["--threads=two", "a"], "--threads needs an integer, not \"two\""),
            (["--timeout", "soon", "a"], "--timeout needs a number, not \"soon\""))
        @test_throws ArgumentError(message) JETSweep.parse_arguments(arguments)
    end
end

@testitem "Command-line entry point" setup=[Execution] begin
    for arguments in (["--help"], ["-h"])
        code, out, err = execution_capture(() -> JETSweep.main(arguments))
        @test code == 0
        @test out == JETSweep.HELP
        @test startswith(out, "jetsweep — ")
        @test isempty(err)
    end
    @test execution_capture(() -> JETSweep.main(["--version"])) == (0, "JETSweep $(pkgversion(JETSweep))\n", "")
    @test execution_capture(() -> JETSweep.main(["a", "b"])) ==
          (2, "", "jetsweep: ArgumentError: give exactly one directory; see `jetsweep --help`\n")
    mktempdir() do directory
        missing = joinpath(directory, "missing")
        code, _, err = execution_capture(() -> JETSweep.main(["--plan", missing]))
        @test code == 2
        @test occursin("not a directory: $missing", err)
        code, _, err = execution_capture(() -> JETSweep.main(["--jobs=0", directory]))
        @test code == 2
        @test occursin("jobs must be positive", err)
        @test isempty(readdir(directory))
    end
    # A checkout that was never instantiated lacks the analyzer: a run fails before writing
    # anything, saying how to instantiate it. A plan needs no analyzer.
    mktempdir() do tool
        cp(joinpath(EXECUTION_PACKAGE, "Project.toml"), joinpath(tool, "Project.toml"))
        loaded = JETSweep._LOADED_PROJECT[]
        JETSweep._LOADED_PROJECT[] = joinpath(tool, "Project.toml")
        try
            mktempdir() do directory
                write(joinpath(directory, "script.jl"), "f() = 1\n")
                code, _, err = execution_capture(() -> JETSweep.main([directory]))
                @test code == 2
                @test err == "jetsweep: JETSweep's project $tool is not instantiated; run " *
                             "`julia --project=$tool -e 'using Pkg; Pkg.instantiate()'` first\n"
                @test readdir(directory) == ["script.jl"]
                @test first(execution_capture(() -> JETSweep.main(["--plan", "--output", joinpath(directory, "plan"),
                                                                   directory]))) == 0
            end
        finally
            JETSweep._LOADED_PROJECT[] = loaded
        end
    end
end

@testitem "only the analyzer needs to be installed" setup=[Execution] begin
    # Packages of JETSweep's environment that the analyzer does not depend on may be missing.
    mktempdir() do tool
        cp(joinpath(EXECUTION_PACKAGE, "Project.toml"), joinpath(tool, "Project.toml"))
        manifest = TOML.parsefile(joinpath(EXECUTION_PACKAGE, "Manifest.toml"))
        manifest["deps"]["NeverInstalled"] = [Dict{String,Any}("uuid" => "6a1a2b3c-4d5e-4f60-8a71-92b3c4d5e6f7",
                                                               "version" => "1.0.0", "git-tree-sha1" => repeat("ab", 20))]
        open(io -> TOML.print(io, manifest), joinpath(tool, "Manifest.toml"), "w")
        loaded = JETSweep._LOADED_PROJECT[]
        JETSweep._LOADED_PROJECT[] = joinpath(tool, "Project.toml")
        try
            @test JETSweep._require_tool() === nothing
        finally
            JETSweep._LOADED_PROJECT[] = loaded
        end
    end
end

@testitem "the analyzer's vendored packages must be the ones JETLS pins" setup=[Execution] begin
    # After a pull moves the JETLS pin, `Pkg.resolve` can keep a vendored package at the old
    # release's revision: a run fails before writing anything, saying how to update it.
    mktempdir() do tool
        cp(joinpath(EXECUTION_PACKAGE, "Project.toml"), joinpath(tool, "Project.toml"))
        manifest = TOML.parsefile(joinpath(EXECUTION_PACKAGE, "Manifest.toml"))
        only(manifest["deps"]["JETLSCore"])["repo-rev"] = repeat("0", 40)
        open(io -> TOML.print(io, manifest), joinpath(tool, "Manifest.toml"), "w")
        loaded = JETSweep._LOADED_PROJECT[]
        JETSweep._LOADED_PROJECT[] = joinpath(tool, "Project.toml")
        try
            mktempdir() do directory
                write(joinpath(directory, "script.jl"), "f() = 1\n")
                code, _, err = execution_capture(() -> JETSweep.main([directory]))
                @test code == 2
                @test err == "jetsweep: JETSweep's project $tool has packages JETLS vendors at other " *
                             "revisions than it pins (JETLSCore); run " *
                             "`julia --project=$tool -e 'using Pkg; Pkg.update()'` first\n"
                @test readdir(directory) == ["script.jl"]
            end
        finally
            JETSweep._LOADED_PROJECT[] = loaded
        end
    end
end

@testitem "Sweeps started in the same second get their own report directories" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        write(joinpath(root, "script.jl"), "f() = 1\n")
        reports = joinpath(root, "reports")
        @test JETSweep._new_directory(reports, "run") == joinpath(reports, "run")
        @test JETSweep._new_directory(reports, "run") == joinpath(reports, "run-2")
        touch(joinpath(reports, "run-3"))
        @test JETSweep._new_directory(reports, "run") == joinpath(reports, "run-4")
        @test isdir(joinpath(reports, "run-2")) && isdir(joinpath(reports, "run-4"))
        # The default report directories of other sweeps started this minute, empty or not.
        started = time()
        taken = [joinpath(root, ".jetsweep", Libc.strftime("%Y%m%d-%H%M%S", started + s)) for s in 0:60]
        foreach(path -> write(joinpath(mkpath(path), "plan.toml"), ""), taken[1:2:end])
        foreach(mkpath, taken[2:2:end])
        result = sweep(root; options=SweepOptions(plan_only=true), io=devnull)
        @test result.output in taken .* "-2"
        @test isfile(joinpath(result.output, "plan.toml"))
        @test all(path -> read(joinpath(path, "plan.toml"), String) == "", taken[1:2:end])
        @test all(path -> isempty(readdir(path)), taken[2:2:end])
    end
end

@testitem "GPU assignment" setup=[Execution] begin
    @test JETSweep._gpus(["none"]) == [""]
    @test JETSweep._gpus(["0", "GPU-1234"]) == ["0", "GPU-1234"]
    withenv("CUDA_VISIBLE_DEVICES" => "5") do
        @test JETSweep._gpus(["none"]) == [""]
        @test JETSweep._gpus(["1"]) == ["1"]
        @test JETSweep._gpus(["auto"]) == ["5"]
    end
    withenv(() -> @test(JETSweep._gpus(["auto"]) == ["1", "3"]), "CUDA_VISIBLE_DEVICES" => " 1, 3 ")
    withenv(() -> @test(JETSweep._gpus(["auto"]) == [""]), "CUDA_VISIBLE_DEVICES" => "")
    withenv(() -> @test(JETSweep._gpus(["auto"]) == [""]), "CUDA_VISIBLE_DEVICES" => "  ")
    mktempdir() do bin
        withenv("CUDA_VISIBLE_DEVICES" => nothing, "PATH" => bin) do
            @test JETSweep._gpus(["auto"]) == String[]
            smi = joinpath(bin, "nvidia-smi")
            write(smi, """
                #!/bin/sh
                [ "\$*" = "--query-gpu=uuid --format=csv,noheader" ] || exit 1
                printf 'GPU-a\\n\\n  GPU-b  \\n'
                """)
            chmod(smi, 0o755)
            @test JETSweep._gpus(["auto"]) == ["GPU-a", "GPU-b"]
            write(smi, "#!/bin/sh\necho GPU-partial\nexit 1\n")
            @test JETSweep._gpus(["auto"]) == String[]
        end
    end
end

@testitem "JETLS configuration" setup=[Execution] begin
    mktempdir() do outer
        write(joinpath(outer, ".JETLSConfig.toml"), "[diagnostic]\npatterns = []\n")
        root = joinpath(outer, "root")
        driver = execution_touch(joinpath(root, "Pkg", "test", "runtests.jl"), EXECUTION_DRIVER)
        helper = execution_touch(joinpath(root, "Pkg", "test", "helper.jl"),
                                 "const LIMIT = 3\nvar\"odd name\" = 4\n")
        separate = [execution_touch(joinpath(root, "Pkg", "test", "sub", "first.jl")),
                    execution_touch(joinpath(root, "Pkg", "test", "second.jl"))]
        unit = execution_unit(driver; expected=[driver, helper])
        # Statically side-effect-free statements of the files the unit loads, matched exactly;
        # `seed = rand()` is not one.
        pure = [("const DIR = @__DIR__", "Pkg/test/runtests.jl"), (EXECUTION_SELECTION, "Pkg/test/runtests.jl"),
                ("const LIMIT = 3", "Pkg/test/helper.jl"), ("var\"odd name\" = 4", "Pkg/test/helper.jl")]

        base, data = execution_jetls(unit, root)
        @test base == root
        @test data["full_analysis"]["auto_instantiate"] == "never"
        # A batch limit on evaluating each top-level statement, not the editor's 10 s.
        @test data["full_analysis"]["concretization_timeout"] == 300.0
        @test data["diagnostic"] == Dict("enabled" => true, "all_files" => true)
        @test Set(execution_patterns(data)) == Set(pure)
        @test !haskey(data, "initialization_options")

        base, data = execution_jetls(unit, root, separate)
        @test base == root
        @test Set(execution_patterns(data)) == Set(pure)
        @test execution_skips(data) == execution_skip.(["Pkg/test/sub/first.jl", "Pkg/test/second.jl"])

        # The nearest configuration applies, with its paths rebased onto the sweep root.
        user = execution_touch(joinpath(root, "Pkg", ".JETLSConfig.toml"), EXECUTION_USER_JETLS)
        execution_touch(joinpath(root, ".JETLSConfig.toml"), "[full_analysis]\ndebounce = 9.0\n")
        execution_touch(joinpath(root, "Other", ".JETLSConfig.toml"))
        base, data = execution_jetls(unit, root, separate)
        @test base == root
        @test read(user, String) == EXECUTION_USER_JETLS
        @test data["full_analysis"]["debounce"] == 2.0
        @test data["full_analysis"]["auto_instantiate"] == "never"
        @test data["full_analysis"]["concretization_timeout"] == 30
        patterns = execution_patterns(data)
        @test first(patterns) == ("const C_ = v_", "")
        @test Set(patterns[2:end]) == Set(pure)
        @test data["diagnostic"]["enabled"] === true && data["diagnostic"]["all_files"] === true
        @test data["diagnostic"]["patterns"] == [Dict("pattern" => "lowering/unused-argument",
              "match_by" => "code", "match_type" => "literal", "severity" => "off")]
        @test execution_skips(data) ==
              execution_skip.(["Pkg/src/generated.jl", "Pkg/test/sub/first.jl", "Pkg/test/second.jl"])

        base, data = execution_jetls(execution_unit(separate[1]), root)
        @test base == root
        @test execution_patterns(data) == [("const C_ = v_", "")]
        @test execution_skips(data) == [execution_skip("Pkg/src/generated.jl")]
        execution_touch(joinpath(dirname(separate[1]), ".JETLSConfig.toml"), "[full_analysis]\ndebounce = 1.0\n")
        base, data = execution_jetls(execution_unit(separate[1]), root)
        @test base == root
        @test data["full_analysis"]["debounce"] == 1.0

        # Package analysis evaluates all top-level code itself; an orphan's script analysis does not.
        package = execution_touch(joinpath(root, "Pkg", "src", "Pkg.jl"), "module Pkg\nconst N = 1\nend\n")
        _, data = execution_jetls(execution_unit(package; kind=:package), root)
        @test execution_patterns(data) == [("const C_ = v_", "")]
        _, data = execution_jetls(execution_unit(package; kind=:orphan), root)
        @test execution_patterns(data)[2:end] == [("const N = 1", "Pkg/src/Pkg.jl")]

        rm(user)
        script = execution_touch(joinpath(root, "scripts", "deep", "run.jl"), "const N = 2 + 3\nx = rand(N)\n")
        setup = execution_touch(joinpath(root, "scripts", "setup.jl"), "const MODE = \"fast\"\n")
        base, data = execution_jetls(execution_unit(script; kind=:script, setup=[setup]), root)
        @test base == root
        @test data["full_analysis"]["debounce"] == 9.0
        @test data["full_analysis"]["concretization_timeout"] == 300.0
        @test Set(execution_patterns(data)) ==
              Set([("const N = 2 + 3", "scripts/deep/run.jl"), ("const MODE = \"fast\"", "scripts/setup.jl")])

        configured = execution_touch(joinpath(root, "Pkg", "sweep.toml"), "[diagnostic]\nenabled = false\n")
        base, data = execution_jetls(execution_unit(driver; jetls_config=configured), root, separate[2:2])
        @test base == root
        @test !haskey(data["full_analysis"], "debounce")
        @test data["diagnostic"] == Dict("enabled" => true, "all_files" => true)
        @test Set(execution_patterns(data)) ==
              Set([("const DIR = @__DIR__", "Pkg/test/runtests.jl"), (EXECUTION_SELECTION, "Pkg/test/runtests.jl")])
        @test execution_skips(data) == [execution_skip("Pkg/test/second.jl")]

        # What run-time includes need is evaluated, pure or not; the driver's unit skips the
        # files analyzed separately.
        listing = execution_touch(joinpath(root, "Listing", "test", "runtests.jl"),
                                  "const PICKED = list_tests()\nfor file in PICKED\n    include(file)\nend\n")
        _, data = execution_jetls(execution_unit(listing), root, separate[2:2])
        @test execution_patterns(data) == [("const PICKED = list_tests()", "Listing/test/runtests.jl")]
        @test execution_skips(data) == [execution_skip("Pkg/test/second.jl")]
    end
end

@testitem "JETLS selects exactly the files the settings are written for" setup=[Execution] begin
    mktempdir() do root
        test = joinpath(root, "Pkg", "test")
        driver = execution_touch(joinpath(test, "runtests.jl"), EXECUTION_DRIVER)
        helper = execution_touch(joinpath(test, "helper[1].jl"), "const K = 1\n")
        separate = execution_touch.(joinpath.(test, ["sub/test_first.jl", "test_case[1].jl", "test_a*.jl"]))
        others = execution_touch.(joinpath.(test, ["helper1.jl", "test_case1.jl", "test_ab.jl"]))
        files = [driver; helper; separate; others]
        base, data = execution_jetls(execution_unit(driver; expected=[driver, helper]), root, separate)
        @test execution_concretized(data, EXECUTION_SELECTION, files, base) == [driver]
        @test execution_concretized(data, "const K = 1", files, base) == [helper]
        @test execution_skipped(data, files, base) == separate
    end
end

@testitem "JETLS applies the settings for files outside the configuration's directory" setup=[Execution] begin
    mktempdir() do root
        driver = execution_touch(joinpath(root, "Pkg", "test", "runtests.jl"), EXECUTION_DRIVER)
        separate = execution_touch(joinpath(root, "Pkg", "test", "test_second.jl"))
        setup = execution_touch(joinpath(root, "tools", "setup.jl"), "const MODE = \"fast\"\n")
        configured = execution_touch(joinpath(root, "tools", "jetls.toml"), "")
        files = [driver, separate, setup]
        base, data = execution_jetls(execution_unit(driver; jetls_config=configured), root, [separate])
        @test execution_concretized(data, EXECUTION_SELECTION, files, base) == [driver]
        @test execution_skipped(data, files, base) == [separate]

        execution_touch(joinpath(root, "Pkg", ".JETLSConfig.toml"), "")
        base, data = execution_jetls(execution_unit(driver; setup=[setup]), root)
        @test execution_concretized(data, "const DIR = @__DIR__", files, base) == [driver]
        @test execution_concretized(data, "const MODE = \"fast\"", files, base) == [setup]
    end
end

@testitem "Report directories are tagged as caches, so later sweeps skip them" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        script = execution_touch(joinpath(root, "script.jl"), "f() = 1\n")
        earlier = sweep(root; options=SweepOptions(plan_only=true, output=joinpath(root, "reports", "a")), io=devnull)
        @test startswith(read(joinpath(earlier.output, "CACHEDIR.TAG"), String),
                         "Signature: 8a477f597d28d172789f06886806bc55\n")
        # What an analysis leaves there: generated entries and prepared environments.
        execution_touch(joinpath(earlier.output, "units", "script-1", "entry.jl"), "include($(repr(script)))\n")
        execution_touch(joinpath(earlier.output, "environments", "1", "env", "Project.toml"), "")
        later = sweep(root; options=SweepOptions(plan_only=true, output=joinpath(root, "reports", "b")), io=devnull)
        @test [source.path for source in later.inventory.sources] == [script]
        @test isempty(later.inventory.projects)
        @test only(later.units).entry == script
        @test isfile(joinpath(sweep(root; options=SweepOptions(plan_only=true), io=devnull).output, "CACHEDIR.TAG"))
    end
end

@testitem "A plan prints the discovery issues that fail it" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        execution_touch(joinpath(root, "Broken", "Project.toml"), "name = \"Broken\"\nuuid = \"not-a-uuid\"\n")
        execution_touch(joinpath(root, "Broken", "src", "Broken.jl"), "module Broken\nend\n")
        io = IOBuffer()
        result = sweep(root; options=SweepOptions(plan_only=true, output=joinpath(root, "plan")), io)
        @test result.exit_code == 2
        @test occursin("\nDiscovery issue: Broken/Project.toml: invalid project UUID \"not-a-uuid\"\nPlan written to ",
                       String(take!(io)))
    end
end

@testitem "Edits to packages the sweep leaves out do not count as changed inputs" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        package(name, uuid) = (execution_touch(joinpath(root, name, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\n");
                               execution_touch(joinpath(root, name, "src", "$name.jl"), "module $name\nend\n"))
        package("Kept", "6f0c2d7e-3b1a-4c5e-9d8f-1a2b3c4d5e01")
        package("Excluded", "6f0c2d7e-3b1a-4c5e-9d8f-1a2b3c4d5e02")
        result = sweep(root; io=devnull, options=SweepOptions(plan_only=true, output=joinpath(root, ".plan"), exclude=["Excluded"]))
        @test [[p.name for p in tier] for tier in result.inventory.available] == [["Excluded"], String[]]
        @test sort!(collect(keys(JETSweep._snapshot(result.inventory, JETSweep.Config())))) ==
              [joinpath(root, "Kept", "Project.toml"), joinpath(root, "Kept", "src", "Kept.jl")]
        written = TOML.parsefile(joinpath(result.output, "inventory.toml"))
        @test [p["name"] for p in written["projects"]] == ["Kept"]
        @test [(p["name"], p["tier"]) for p in written["available"]] == [("Excluded", 1)]
    end
end

@testitem "A context that selects no unit is a mistake, unless the sweep leaves out what it selects" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        execution_touch(joinpath(root, "Swept", "tools", "check.jl"), "include(\"lib.jl\")\n")
        execution_touch(joinpath(root, "Swept", "tools", "lib.jl"))
        execution_touch(joinpath(root, "Swept", "tools", "generated.jl"))
        execution_touch(joinpath(root, "Other", "run.jl"))
        config = execution_touch(joinpath(root, ".JETSweep.toml"), """
            exclude = ["Swept/tools/generated.jl"]
            [[context]]
            match = "Swept/tools/check.jl"
            args = ["--fast"]
            [[context]]
            match = "Other/run.jl"
            args = ["--other"]
            """)
        n = Ref(0)
        planned(directory=root; options...) = sweep(directory; io=devnull,
            options=SweepOptions(; plan_only=true, output=joinpath(root, ".reports", string(n[] += 1)), options...))
        args(result) = Dict(relpath(unit.entry, root) => unit.overrides.args for unit in result.units)
        note = "$config: [[context]] match \"Other/run.jl\" selects no unit of this sweep, which leaves out the files it selects"
        @test isempty(planned().notes)
        @test args(planned()) == Dict("Swept/tools/check.jl" => ["--fast"], "Other/run.jl" => ["--other"])
        # Excluding its files, or sweeping a directory without them with the configuration of the
        # one above, whose paths and globs are relative to it, leaves a context nothing to select.
        excluded = planned(exclude=["Other"])
        narrower = planned(joinpath(root, "Swept"); config)
        for result in (excluded, narrower)
            @test result.notes == [note] && result.exit_code == 0
            @test args(result) == Dict("Swept/tools/check.jl" => ["--fast"])
            @test TOML.parsefile(joinpath(result.output, "plan.toml"))["notes"] == [note]
        end
        # A configuration whose directory is not above the one swept matches relative to that.
        external = execution_touch(joinpath(root, "Other", "swept.toml"), "[[context]]\nmatch = \"tools/check.jl\"\nargs = [\"--external\"]\n")
        @test args(planned(joinpath(root, "Swept"); config=external))["Swept/tools/check.jl"] == ["--external"]
        io = IOBuffer()
        sweep(root; io, options=SweepOptions(plan_only=true, output=joinpath(root, ".reports", "io"), exclude=["Other"]))
        @test occursin("\nNote: .JETSweep.toml: [[context]] match \"Other/run.jl\" selects no unit of this sweep", String(take!(io)))
        # A context that selects no unit of the full sweep either is a mistake, also one that selects
        # only a file that another unit covers or the configuration excludes.
        for match in ("Other/absent.jl", "Swept/tools/lib.jl", "Swept/tools/generated.jl")
            write(config, "exclude = [\"Swept/tools/generated.jl\"]\n[[context]]\nmatch = \"$match\"\n")
            message = "ArgumentError: $config: [[context]] match $(repr(match)) selects no unit"
            @test_throws message planned()
            @test_throws message planned(exclude=["Swept"])
            @test_throws message planned(joinpath(root, "Other"); config)
        end
    end
end

@testitem "The units of an unavailable environment point to its log, if it has one" setup=[Execution] begin
    mktempdir() do output
        unit = execution_unit(execution_touch(joinpath(output, "root", "script.jl")); kind=:script)
        sweep = execution_sweep(unit, joinpath(output, "root"), output)
        failed = JETSweep.Environment(:failed, joinpath(output, "environments", "env"), "invalid project")
        result = JETSweep._analyze(unit, failed, sweep, nothing)
        @test (result.status, result.reasons, result.log) == (:unavailable, ["environment unavailable: invalid project"], "")
        @test !ispath(joinpath(output, "units"))
        log = execution_touch(joinpath(output, "environments", JETSweep._context_key(unit.context), "log.txt"), "")
        @test JETSweep._analyze(unit, failed, sweep, nothing).log == ""
        write(log, "ERROR: preparation failed\n")
        @test JETSweep._analyze(unit, failed, sweep, nothing).log == log
    end
end

@testitem "Incomplete units are grouped by cause, whichever environment's log it points to" setup=[Execution] begin
    mktempdir() do output
        timed_out(key) = "environment unavailable: environment preparation timed out; see $output/environments/$key/log.txt"
        exited(key) = "environment unavailable: environment preparation exited with code 1; see /out dir/$key/log.txt"
        units = execution_script.(["a", "b", "c", "d"])
        results = [execution_incomplete("a", :unavailable, [timed_out("1")]),
                   execution_incomplete("b", :unavailable, [timed_out("2")]),
                   execution_incomplete("c", :unavailable, [exited("3")]),
                   execution_incomplete("d", :unavailable, [exited("4")])]
        @test JETSweep._cause(results[1]) == "environment unavailable: environment preparation timed out"
        @test JETSweep._cause(results[3]) == "environment unavailable: environment preparation exited with code 1"
        terminal, _ = execution_report(output, units, results)
        @test occursin("\n    2  unavailable environment unavailable: environment preparation timed out\n" *
                       "         a.jl, b.jl\n", terminal)
        @test occursin("\n    2  unavailable environment unavailable: environment preparation exited with code 1\n" *
                       "         c.jl, d.jl\n", terminal)
    end
end

@testitem "The summary shows an incomplete unit's notes with its reasons" setup=[Execution] begin
    mktempdir() do output
        stop = "analysis stopped at /root/report.jl:1 [toplevel/error]: JET could not execute this top-level code: " *
               "ArgumentError: Package Humanize not found in current path.\n- Run `import Pkg; Pkg.add(\"Humanize\")`"
        left_out = "environment: Packages imported without being declared that could not be added: Humanize " *
                   "(downloads are disabled, and the installed packages do not satisfy this context)."
        units = execution_script.(["report", "clean"])
        results = [execution_incomplete("report", :incomplete, [stop], [left_out]; log="/out/units/script-report/log.txt"),
                   execution_incomplete("clean", :clean, String[], ["environment: Precompilation timed out."])]
        _, summary = execution_report(output, units, results)
        @test occursin("""
            incomplete  report.jl
                analysis stopped at report.jl:1 [toplevel/error]: JET could not execute this top-level code: \
            ArgumentError: Package Humanize not found in current path.
                note: $left_out
                log: /out/units/script-report/log.txt
            """, summary)
        @test !occursin("Precompilation", summary)
    end
end

@testitem "Files a unit did not reach get follow-up units" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        package = joinpath(root, "Pkg")
        entry = execution_touch(joinpath(package, "src", "Pkg.jl"), "module Pkg\nend\n")
        inactive = execution_touch(joinpath(package, "src", "inactive.jl"), "include(\"part.jl\")\n")
        part = execution_touch(joinpath(package, "src", "part.jl"))
        test = execution_touch(joinpath(package, "test", "runtests.jl"), "include(\"helper.jl\")\n")
        helper = execution_touch(joinpath(package, "test", "helper.jl"), "include(\"leaf.jl\")\n")
        leaf = execution_touch(joinpath(package, "test", "leaf.jl"))
        inventory = discover(root)
        sweep = JETSweep._Sweep(inventory, root, SweepOptions(), JETSweep.source_syntax(inventory),
                                Dict{String,JETSweep.Unit}(), Dict{String,Vector{String}}(),
                                Dict{Tuple{String,Vector{Symbol}},Vector{String}}())
        analyzed(files...) = JETSweep.UnitResult("unit", :incomplete, JETSweep.Finding[], [realpath.(files)...],
                                                 String[], String[], 0.0, "")
        # An extension's orphans load in its context and module, with its run-time settings.
        context = JETSweep.Context(package, package, false, Dict("Trigger" => string(Base.UUID(1))))
        settings = JETSweep.Overrides(; setup=["setup.jl"], args=["--fast"], env=Dict("MODE" => "x"))
        unit = JETSweep.Unit("extension-unit", :extension, entry, context, [entry, inactive, part], "", "PkgExt",
                             settings, String[])
        orphan = only(JETSweep._followups(unit, analyzed(entry), sweep, Set([entry])))
        @test (orphan.kind, orphan.entry, orphan.expected, orphan.context) == (:orphan, inactive, [inactive, part], context)
        @test orphan.extension == "PkgExt"
        @test (orphan.overrides.setup, orphan.overrides.args, orphan.overrides.env) == (String[], ["--fast"], Dict("MODE" => "x"))
        @test isempty(JETSweep._followups(unit, analyzed(entry), sweep, Set([entry, inactive, part])))
        failed = JETSweep.UnitResult("unit", :failed, JETSweep.Finding[], String[], ["load error"], String[], 0.0, "")
        @test isempty(JETSweep._followups(unit, failed, sweep, Set([entry])))

        # A file of a submodule cannot be analyzed in its scope by itself, so it stays uncovered.
        scoped = execution_touch(joinpath(root, "Scoped", "src", "Scoped.jl"),
                                 "module Scoped\nmodule Sub\nif false\n    include(\"sub.jl\")\nend\nend\nend\n")
        sub = execution_touch(joinpath(root, "Scoped", "src", "sub.jl"))
        scoped_sweep = JETSweep._Sweep(sweep.inventory, root, SweepOptions(),
                                       Dict(scoped => JETSweep.parse_source(scoped)), Dict{String,JETSweep.Unit}(),
                                       Dict{String,Vector{String}}(), Dict{Tuple{String,Vector{Symbol}},Vector{String}}())
        scoped_unit = JETSweep.Unit("package-scoped", :package, scoped, context, [scoped, sub], "", "",
                                    JETSweep.Overrides(), String[])
        @test isempty(JETSweep._followups(scoped_unit, analyzed(scoped), scoped_sweep, Set([scoped])))

        tests = JETSweep.Context(package, package, true, Dict{String,String}())
        overrides = JETSweep.Overrides(; args=["--quick"])
        unit = JETSweep.Unit("test-unit", :test, test, tests, [test, helper, leaf], "", "", overrides, String[])
        followup = only(JETSweep._followups(unit, analyzed(test), sweep, Set([test])))
        # The unreached helper covers the leaf it includes, in the same context, after the driver.
        @test (followup.kind, followup.entry, followup.expected) == (:test, helper, [helper, leaf])
        @test (followup.context, followup.driver, followup.overrides.args) == (tests, test, ["--quick"])
    end
end

@testitem "A repeated sweep schedules the longest analyses first" setup=[Execution] begin
    mktempdir() do directory
        root = realpath(directory)
        @test isempty(JETSweep._previous_seconds(root))
        version = string(pkgversion(JETSweep))
        function report(run, results; jetsweep=version)
            file = joinpath(root, ".jetsweep", run, "report.toml")
            mkpath(dirname(file))
            open(io -> TOML.print(io, Dict("jetsweep" => jetsweep, "results" => results)), file, "w")
            sleep(0.01)
        end
        result(unit, seconds, status="clean") = Dict("unit" => unit, "seconds" => seconds, "status" => status)
        report("1", [result("test-slow", 5.0)])
        report("2", [result("test-slow", 200.0), result("test-stopped", 300.0, "incomplete"),
                     result("test-failed", 1.0, "failed")])
        previous = JETSweep._previous_seconds(root)
        # Analyses that ran tell how long one takes; failed ones do not.
        @test previous == Dict("test-slow" => 200.0, "test-stopped" => 300.0)
        # Another version of JETSweep may take differently long.
        report("3", [result("test-slow", 1.0)]; jetsweep="0.0.1")
        @test isempty(JETSweep._previous_seconds(root))
        rm(joinpath(root, ".jetsweep", "3"); recursive=true)
        small = execution_touch(joinpath(root, "small.jl"))
        slow = JETSweep.Unit("test-slow", :test, small, execution_context("a"), [small], "", "",
                             JETSweep.Overrides(), String[])
        fresh = JETSweep.Unit("test-fresh", :test, small, execution_context("a"), [small], "", "",
                              JETSweep.Overrides(), String[])
        @test JETSweep._cost(slow, previous) == 200.0
        @test JETSweep._cost(fresh, previous) < 20
        @test JETSweep._task(slow, previous).priority < JETSweep._task(fresh, previous).priority
        package = JETSweep.Unit("package-x", :package, small, execution_context("a"), [small], "", "",
                                JETSweep.Overrides(), String[])
        # Package analyses run on several threads but use about one core.
        @test JETSweep._task(package, previous).weight == JETSweep._task(slow, previous).weight == 1
        write(joinpath(root, ".jetsweep", "2", "report.toml"), "not toml [")
        @test isempty(JETSweep._previous_seconds(root))
    end
end

@testitem "a worker that exits without a result is reported with its error" setup=[Execution] begin
    mktempdir() do directory
        log = joinpath(directory, "log.txt")
        @test JETSweep._worker_error(log, 1) === nothing
        write(log, "ERROR: caught\nStacktrace:\nERROR: LoadError: ArgumentError: Cannot load Revise\nStacktrace:\n")
        @test JETSweep._worker_error(log, 1) == ": LoadError: ArgumentError: Cannot load Revise"
        # A signal ends a worker without an error of its own.
        @test JETSweep._worker_error(log, 137) === nothing
        write(log, "killed\n")
        @test JETSweep._worker_error(log, 1) === nothing
    end
end
