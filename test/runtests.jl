# JETSweep's suite: the test items of test/*_tests.jl, run by ReTestItems on NWORKERS worker processes.
# `Pkg.test(test_args=["planning_tests.jl"])` runs the items of the files it names. JETSweep does not check its
# suite with DispatchCheckup, so there is no checked run here and no original= file.
#
# Most of the time goes to the analysis and preparation workers that the sweeps and preparations start
# themselves, most in the sweeps' item, the first item of 0_integration_tests.jl: its four sweeps ask for 14 at
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
const SELECTED = isempty(ARGS) ? filter(endswith("_tests.jl"), readdir(@__DIR__)) : ARGS

# Workers load the analyzer compiled with Julia's default code generation flags and JETLS's development mode, as
# prepared environments have it. Precompile one such environment while the first items run: the sweeps would
# otherwise compile it once per environment they prepare at the same time, and the preparations in depots of their
# own again. The items that start such workers (setup = [Analyzer]) wait until it has finished, when this process
# makes the file ANALYZER_READY. A failed precompile costs only time: the sweeps then compile the analyzer
# themselves.
const ANALYZER_READY = joinpath(mktempdir(), "analyzer-ready")
if any(in(SELECTED), ("0_integration_tests.jl", "environments_tests.jl"))
    let environment = JETSweep.prepare(JETSweep.Context("", "", false, Dict{String,String}()), mktempdir())
        JETSweep.ready(environment) || error("cannot prepare an analysis environment: ", environment.message)
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        command = `$julia --startup-file=no --project=$(environment.dir) -e 'using Pkg; Pkg.precompile()'`
        process = run(addenv(command, "JULIA_LOAD_PATH" => "@:@stdlib"); wait=false)
        @async begin
            success(process) || @warn "Precompiling the analyzer failed; the sweeps compile it themselves"
            touch(ANALYZER_READY)
        end
    end
else
    touch(ANALYZER_READY)
end

paths = isempty(ARGS) ? [@__DIR__] : [joinpath(@__DIR__, f) for f in ARGS]
# (No full garbage collection after each item: these workers' heaps are large, and measured side by side, the runs
# without it were faster.) The item timeout, 1200 s, is above the sweeps' own 900 s limit per unit, so a unit that
# hangs is reported by its sweep, and leaves the sweeps' item (about 300 s on 8 vCPUs) room on CI's 4 vCPUs.
ReTestItems.runtests(paths...; nworkers=NWORKERS, nworker_threads=1, retries=0, testitem_timeout=1200,
                     validate_paths=true, gc_between_testitems=false,
                     test_end_expr=Expr(:block, WRITE_COVERAGE, WORKER_CHECKS),
                     worker_init_expr=:(const MAIN_CHECK_BOUNDS = $(Base.JLOptions().check_bounds);
                                        const MAIN_DEPWARN = $(Base.JLOptions().depwarn);
                                        const MAIN_PATHOF = $(pathof(JETSweep));
                                        const MAIN_DISPATCH_CHECKUP = $(get(ENV, "DISPATCH_CHECKUP", ""));
                                        const ANALYZER_READY = $ANALYZER_READY))
