# JETSweep's suite: the test items of test/*_test.jl, run by ReTestItems on NWORKERS worker processes.
# `Pkg.test(test_args=["units_test.jl"])` runs the items of the files it names. JETSweep does not check its
# suite with DispatchCheckup, so there is no checked run here and no original= file.
#
# Most of the time goes to the analysis and preparation workers that the sweeps and preparations start
# themselves, most in the sweeps' item, the first item of 0_integration_test.jl: its four sweeps ask for 14 at
# once and share the slots JETSweep allows a process, one per CPU thread and per 3 GiB of free memory
# (`JETSweep.worker_cap`: 8 on an 8-vCPU slot here, 3 on the CI runner's 4 vCPUs and 16 GB). ReTestItems starts
# its first worker on the first item of the files by name, so the sweeps start at once; the other workers take
# the rest. That is ReTestItems 1.35's scheduling, not its API: after a ReTestItems upgrade, check that the log's
# first `START (  1/...)` line is the sweeps' item, on worker 1.
using JETSweep, ReTestItems

const NWORKERS = 3   # measured at 2, 3, 4 and 6: see the report
# ReTestItems kills a worker a moment after its last item, which can cut off the coverage file it writes at exit: under
# coverage every worker also writes its tracefile after each item, as <file>-items.info (a no-op without coverage).
const WRITE_COVERAGE = :(let out = Base.JLOptions().output_code_coverage
    out == C_NULL || ccall(:jl_write_coverage_data, Cvoid, (Cstring,), replace(unsafe_string(out), r"\.info$" => "-items.info"))
end)
# After each item, every worker proves that it runs as the main process does: with its flags (deprecations are errors;
# `julia --depwarn=error -e 'using Pkg; Pkg.test()'` hands the flag to the test process, its precompile workers and its
# test workers, and a cache built without it would hide them), and with JETSweep as the main process has it: unchecked,
# without the hidden submodule `#DispatchCheckup` that a checked run's overlay would give it.
const WORKER_CHECKS = :(let checked = Main.MAIN_DISPATCH_CHECKUP == "checked"
    @test Base.JLOptions().depwarn == 2
    @test Base.JLOptions().check_bounds == Main.MAIN_CHECK_BOUNDS
    @test get(ENV, "DISPATCH_CHECKUP", "") == Main.MAIN_DISPATCH_CHECKUP
    @test isdefined(JETSweep, Symbol("#DispatchCheckup")) == checked
end)
const SELECTED = isempty(ARGS) ? filter(endswith("_test.jl"), readdir(@__DIR__)) : ARGS

# Workers run with Julia's default code generation flags, whatever flags this process has, so they need package images
# of their own, which a fresh depot does not have. Analysis workers load the analyzer with JETLS's development mode, as
# prepared environments have it: precompile one such environment while the first items run. The sweeps would
# otherwise compile it once per environment they prepare at the same time, and the preparations in depots of their
# own again. Preparation workers, and the workers some items start, load JETSweep itself from its own project: compile
# its image for them too, and only its own. When a process loads a package that has no image, Julia precompiles all
# the package's dependencies first, so without it the first such worker in each depot compiled JETLS, without the
# development mode, for nothing that loads it: on a fresh 4-vCPU runner, the sweeps' first preparation and the Git
# clone items' workers, in depots of their own, compiled JETLSCore four times, three of them at once, at 134 to 168 s
# and 2.8 to 3.0 GiB each, and the sweeps' item ran out of time. The items that start such workers
# (setup = [Analyzer]) wait until both have finished, when this process makes the file ANALYZER_READY. A failed
# precompile costs only time: the workers then compile what they need themselves.
const ANALYZER_READY = joinpath(mktempdir(), "analyzer-ready")
if any(in(SELECTED), ("0_integration_test.jl", "preparation_test.jl"))
    let environment = JETSweep.prepare(JETSweep.Context("", "", false, Dict{String,String}()), mktempdir())
        JETSweep.ready(environment) || error("cannot prepare an analysis environment: ", environment.message)
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        command = `$julia --startup-file=no --project=$(environment.dir) -e 'using Pkg; Pkg.precompile()'`
        analyzer = run(addenv(command, "JULIA_LOAD_PATH" => "@:@stdlib"); wait=false)
        # JETSweep alone, in a process that `JETSweep.julia_command` starts, as its workers are.
        script = joinpath(mktempdir(), "compile.jl")
        write(script, "pkg = Base.identify_package(\"JETSweep\")\nBase.isprecompiled(pkg) || Base.compilecache(pkg)\n")
        tool = run(JETSweep.julia_command(script, String[]; project=dirname(JETSweep.tool_project()), threads=1); wait=false)
        @async begin
            success(analyzer) || @warn "Precompiling the analyzer failed; the sweeps compile it themselves"
            success(tool) || @warn "Precompiling JETSweep for its workers failed; they compile it themselves"
            touch(ANALYZER_READY)
        end
    end
else
    touch(ANALYZER_READY)
end

paths = isempty(ARGS) ? [@__DIR__] : [joinpath(@__DIR__, f) for f in ARGS]
# (No full garbage collection after each item: these workers' heaps are large, and measured side by side, the runs
# without it were faster.) The item timeout, 1200 s, is above the sweeps' own 900 s limit per unit, so a unit that
# hangs is reported by its sweep, and leaves the sweeps' item room on CI's runner. With CI's command and a fresh depot,
# in a 4-vCPU, 16 GiB cgroup whose precompile step took 231 s (200 to 320 s on the hosted runners), the item took 617
# to 669 s, of which 193 to 222 s waiting for the precompiles above, and 858 to 979 s before they included JETSweep's
# image.
ReTestItems.runtests(paths...; nworkers=NWORKERS, nworker_threads=1, retries=0, testitem_timeout=1200,
                     validate_paths=true, gc_between_testitems=false,
                     test_end_expr=Expr(:block, WRITE_COVERAGE, WORKER_CHECKS),
                     worker_init_expr=:(const MAIN_CHECK_BOUNDS = $(Base.JLOptions().check_bounds);
                                        const MAIN_DEPWARN = $(Base.JLOptions().depwarn);
                                        const MAIN_PATHOF = $(pathof(JETSweep));
                                        const MAIN_DISPATCH_CHECKUP = $(get(ENV, "DISPATCH_CHECKUP", ""));
                                        const ANALYZER_READY = $ANALYZER_READY))
