using Test, JETSweep, TOML

execution_context(name) = JETSweep.Context("/execution/$name", "", false, Dict{String,String}())
execution_task(name, weight=1, priority=(0, 0)) = JETSweep._Task(weight, priority, execution_context(name))
execution_name(task) = basename(task.work.project)

"Dispatch `tasks`, recording start and end events and the peak clamped weight in use."
function execution_trace(tasks, capacity; followups=Dict{String,Vector{JETSweep._Task}}(), pause=0.02)
    load, peak, events = Ref(0), Ref(0), String[]
    dispatcher = @async JETSweep._dispatch(tasks, capacity) do task
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

@testset "Dispatch runs every task once, in priority order, within capacity" begin
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

@testset "A task that does not fit blocks later tasks" begin
    tasks = [execution_task("C", 1, (0, 2)), execution_task("A", 2, (0, 0)), execution_task("B", 2, (0, 1))]
    trace = execution_trace(tasks, 3)
    @test trace.starts == ["A", "B", "C"]
    @test findfirst(==("start C"), trace.events) > findfirst(==("end A"), trace.events)
    @test trace.peak == 3
end

@testset "Weight above capacity is clamped and runs alone" begin
    trace = execution_trace([execution_task("L", 1, (0, 1)), execution_task("H", 10, (0, 0))], 2)
    @test trace.events == ["start H", "end H", "start L", "end L"]
    @test trace.peak == 2
    @test execution_trace([execution_task("H", 100)], 1).events == ["start H", "end H"]
end

@testset "Follow-up tasks are scheduled by priority" begin
    tasks = [execution_task("A", 1, (0, 0)), execution_task("B", 1, (2, 0)), execution_task("C", 1, (0, 1))]
    followups = Dict("A" => [execution_task("F", 1, (1, 0)), execution_task("E", 1, (0, -5))],
                     "F" => [execution_task("G", 1, (3, 0))])
    @test execution_trace(tasks, 1; followups).starts == ["A", "E", "C", "F", "B", "G"]
    trace = execution_trace(tasks, 2; followups)
    @test sort(trace.starts) == ["A", "B", "C", "E", "F", "G"]
    @test trace.peak <= 2
end

@testset "A failing step stops new tasks and propagates once running tasks finish" begin
    events, failed = String[], Base.Event()
    tasks = [execution_task("slow", 1, (0, 0)), execution_task("bad", 1, (0, 1)),
             (execution_task("rest$i", 1, (1, i)) for i in 1:3)...]
    failure = try
        JETSweep._dispatch(tasks, 2) do task
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

function execution_alive(pid::Integer)
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 || return false
    Sys.islinux() || return true
    # A killed orphan may briefly wait for its new parent to reap it.
    stat = try
        read("/proc/$pid/stat", String)
    catch
        return false
    end
    return split(stat[findlast(')', stat)+1:end])[1] != "Z"
end

execution_sh(script, args...) = Cmd(["/bin/sh", "-c", script, "sh", args...])

function execution_gone(pid::Integer)
    timedwait(() -> !execution_alive(pid), 5.0; pollint=0.05)
    gone = !execution_alive(pid)
    gone || ccall(:kill, Cint, (Cint, Cint), pid, Base.SIGKILL)
    return gone
end

@testset "Worker exit codes, signals and logs" begin
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

@testset "Worker process groups are terminated" begin
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

@testset "Worker Julia command" begin
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
                           "--compiled-modules=yes", "--threads=3,1", "--project=/environment",
                           "/scripts/worker.jl", "a", "b c"]
    cached = JETSweep.julia_command("/scripts/worker.jl", String[]; project="/environment", threads=1,
                                    compile=false)
    @test "--compiled-modules=existing" in cached.exec && "--threads=1,1" in cached.exec
    mktempdir() do directory
        script = joinpath(directory, "probe.jl")
        write(script, """
            println(Threads.nthreads(:default), " ", Threads.nthreads(:interactive))
            println(join(LOAD_PATH, ':'))
            println(get(ENV, "JULIA_PROJECT", "unset"))
            println(join(ARGS, '|'))
            println(Base.JLOptions().check_bounds)
            """)
        command = withenv("JULIA_PROJECT" => directory) do
            JETSweep.julia_command(script, ["x", "y z"]; project=directory, threads=2)
        end
        log = joinpath(directory, "probe.log")
        @test JETSweep.run_worker(command, log, 300.0) == (code=0, timed_out=false)
        # Default code generation (check_bounds 0) even when this process runs `--check-bounds=yes`.
        @test readlines(log) == ["2 1", "@:@stdlib", "unset", "x|y z", "0"]
    end
end

execution_finding(severity; file="/root/a.jl", line=1, code="code", message="message") =
    JETSweep.Finding(file, line, 1, line, 5, severity, code, message)
execution_result(status, findings=JETSweep.Finding[]) =
    JETSweep.UnitResult("unit", status, findings, String[], String[], String[], 0.0, "")
execution_inventory(issues=String[]) =
    JETSweep.Inventory("/root", JETSweep.Project[], JETSweep.Source[], String[], issues)

@testset "Exit codes" begin
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

@testset "Unique findings" begin
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

@testset "Command-line arguments" begin
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
    directory, options = JETSweep.parse_arguments(["workspace"])
    @test directory == "workspace"
    defaults = SweepOptions()
    @test all(name -> getfield(options, name) == getfield(defaults, name), fieldnames(SweepOptions))
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
    @test_throws ArgumentError JETSweep.parse_arguments(["--jobs", "many", "a"])
    @test_throws ArgumentError JETSweep.parse_arguments(["--timeout", "soon", "a"])
end

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

@testset "Command-line entry point" begin
    for arguments in (["--help"], ["-h"])
        code, out, err = execution_capture(() -> JETSweep.main(arguments))
        @test code == 0
        @test out == JETSweep.HELP
        @test startswith(out, "jetsweep — ")
        @test isempty(err)
    end
    code, out, err = execution_capture(() -> JETSweep.main(["--version"]))
    @test code == 0
    @test out == "JETSweep $(pkgversion(JETSweep))\n"
    @test isempty(err)
    code, out, err = execution_capture(() -> JETSweep.main(["a", "b"]))
    @test code == 2
    @test isempty(out)
    @test err == "jetsweep: ArgumentError: give exactly one directory; see `jetsweep --help`\n"
    mktempdir() do directory
        missing = joinpath(directory, "missing")
        code, out, err = execution_capture(() -> JETSweep.main(["--plan", missing]))
        @test code == 2
        @test occursin("not a directory: $missing", err)
        code, out, err = execution_capture(() -> JETSweep.main(["--jobs=0", directory]))
        @test code == 2
        @test occursin("jobs must be positive", err)
        @test isempty(readdir(directory))
    end
end

@testset "GPU assignment" begin
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

execution_unit(entry; kind=:test, expected=[entry], setup=String[], jetls_config="") =
    JETSweep.Unit("$kind-unit", kind, entry, execution_context("unit"), expected, "", "",
                  JETSweep.Overrides(; setup, jetls_config), String[])

function execution_jetls(unit, root, separate=String[])
    directory = mktempdir()
    base = JETSweep._write_jetls_config(unit, directory, root, separate)
    return base, TOML.parsefile(joinpath(directory, "config", ".JETLSConfig.toml"))
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

@testset "JETLS configuration" begin
    mktempdir() do outer
        write(joinpath(outer, ".JETLSConfig.toml"), "[diagnostic]\npatterns = []\n")
        root = joinpath(outer, "root")
        driver = execution_touch(joinpath(root, "Pkg", "test", "runtests.jl"), EXECUTION_DRIVER)
        helper = execution_touch(joinpath(root, "Pkg", "test", "helper.jl"),
                                 "const LIMIT = 3\nvar\"odd name\" = 4\n")
        separate = [execution_touch(joinpath(root, "Pkg", "test", "sub", "first.jl")),
                    execution_touch(joinpath(root, "Pkg", "test", "second.jl"))]
        unit = execution_unit(driver; expected=[driver, helper])
        # Statically side-effect-free statements, matched exactly; `seed = rand()` is not one.
        pure = [("const DIR = @__DIR__", "Pkg/test/runtests.jl"), ("const LIMIT = 3", "Pkg/test/helper.jl"),
                ("var\"odd name\" = 4", "Pkg/test/helper.jl")]

        base, data = execution_jetls(unit, root)
        @test base == root
        @test data["full_analysis"]["auto_instantiate"] == "never"
        @test data["diagnostic"] == Dict("enabled" => true, "all_files" => true)
        @test Set(execution_patterns(data)) == Set(pure)
        @test !haskey(data, "initialization_options")

        base, data = execution_jetls(unit, root, separate)
        @test base == root
        @test Set(execution_patterns(data)) == Set([pure; (EXECUTION_SELECTION, "Pkg/test/runtests.jl")])
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
        patterns = execution_patterns(data)
        @test first(patterns) == ("const C_ = v_", "")
        @test Set(patterns[2:end]) == Set([pure; (EXECUTION_SELECTION, "Pkg/test/runtests.jl")])
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
        base, data = execution_jetls(execution_unit(package; kind=:package), root)
        @test execution_patterns(data) == [("const C_ = v_", "")]
        _, data = execution_jetls(execution_unit(package; kind=:orphan), root)
        @test execution_patterns(data)[2:end] == [("const N = 1", "Pkg/src/Pkg.jl")]

        rm(user)
        script = execution_touch(joinpath(root, "scripts", "deep", "run.jl"), "const N = 2 + 3\nx = rand(N)\n")
        setup = execution_touch(joinpath(root, "scripts", "setup.jl"), "const MODE = \"fast\"\n")
        base, data = execution_jetls(execution_unit(script; kind=:script, setup=[setup]), root)
        @test base == root
        @test data["full_analysis"]["debounce"] == 9.0
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
    end
end

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

@testset "JETLS selects exactly the files the settings are written for" begin
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

@testset "JETLS applies the settings for files outside the configuration's directory" begin
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

@testset "Files a unit did not reach get follow-up units" begin
    mktempdir() do directory
        root = realpath(directory)
        package = joinpath(root, "Pkg")
        entry = execution_touch(joinpath(package, "src", "Pkg.jl"), "module Pkg\nend\n")
        inactive = execution_touch(joinpath(package, "src", "inactive.jl"))
        test = execution_touch(joinpath(package, "test", "runtests.jl"), "include(\"helper.jl\")\n")
        helper = execution_touch(joinpath(package, "test", "helper.jl"), "include(\"leaf.jl\")\n")
        leaf = execution_touch(joinpath(package, "test", "leaf.jl"))
        inventory = discover(root)
        sources = Dict(source.path => source for source in inventory.sources)
        analyzed(files...) = JETSweep.UnitResult("unit", :incomplete, JETSweep.Finding[], [realpath.(files)...],
                                                 String[], String[], 0.0, "")
        context = JETSweep.Context(package, package, false, Dict{String,String}())
        unit = JETSweep.Unit("package-unit", :package, entry, context, [entry, inactive], "", "",
                             JETSweep.Overrides(), String[])
        orphan = only(JETSweep._followups(unit, analyzed(entry), inventory, Set([entry]), sources))
        @test (orphan.kind, orphan.entry, orphan.expected, orphan.context) == (:orphan, inactive, [inactive], context)
        @test isempty(JETSweep._followups(unit, analyzed(entry), inventory, Set([entry, inactive]), sources))
        failed = JETSweep.UnitResult("unit", :failed, JETSweep.Finding[], String[], ["load error"], String[], 0.0, "")
        @test isempty(JETSweep._followups(unit, failed, inventory, Set([entry]), sources))

        tests = JETSweep.Context(package, package, true, Dict{String,String}())
        overrides = JETSweep.Overrides(; args=["--quick"])
        unit = JETSweep.Unit("test-unit", :test, test, tests, [test, helper, leaf], "", "", overrides, String[])
        followup = only(JETSweep._followups(unit, analyzed(test), inventory, Set([test]), sources))
        # The unreached helper covers the leaf it includes, in the same context, after the driver.
        @test (followup.kind, followup.entry, followup.expected) == (:test, helper, [helper, leaf])
        @test (followup.context, followup.driver, followup.overrides.args) == (tests, test, ["--quick"])
    end
end

@testset "A repeated sweep schedules the longest analyses first" begin
    mktempdir() do directory
        root = realpath(directory)
        @test isempty(JETSweep._previous_seconds(root))
        for (run, seconds) in (("1", 5.0), ("2", 200.0))
            report = joinpath(root, ".jetsweep", run, "report.toml")
            mkpath(dirname(report))
            open(io -> TOML.print(io, Dict("results" => [Dict("unit" => "test-slow", "seconds" => seconds)])), report, "w")
            touch(report)
            sleep(0.01)
        end
        previous = JETSweep._previous_seconds(root)
        @test previous == Dict("test-slow" => 200.0)
        small = execution_touch(joinpath(root, "small.jl"))
        slow = JETSweep.Unit("test-slow", :test, small, execution_context("a"), [small], "", "",
                             JETSweep.Overrides(), String[])
        fresh = JETSweep.Unit("test-fresh", :test, small, execution_context("a"), [small], "", "",
                              JETSweep.Overrides(), String[])
        @test JETSweep._cost(slow, previous) == 200.0
        @test JETSweep._cost(fresh, previous) < 20
        options = SweepOptions(threads=3)
        @test JETSweep._task(slow, options, previous).priority < JETSweep._task(fresh, options, previous).priority
        package = JETSweep.Unit("package-x", :package, small, execution_context("a"), [small], "", "",
                                JETSweep.Overrides(), String[])
        @test JETSweep._task(package, options, previous).weight == 3
        @test JETSweep._task(slow, options, previous).weight == 1
        write(joinpath(root, ".jetsweep", "2", "report.toml"), "not toml [")
        @test isempty(JETSweep._previous_seconds(root))
    end
end
