# JETSweep's suite: the test items of test/*_tests.jl, run by ReTestItems on NWORKERS worker processes.
# `Pkg.test(test_args=["planning_tests.jl"])` runs the items of the files it names. JETSweep does not check its
# suite with DispatchCheckup, so there is no checked run here and no original= file.
#
# Most of the time goes to the analysis and preparation workers that the sweeps and preparations start
# themselves: up to 14 at once in the sweeps' item, the first item of 0_integration_tests.jl. ReTestItems starts
# its first worker on the first item of the files by name, so the sweeps start at once; the other workers take
# the rest. That is ReTestItems 1.35's scheduling, not its API: after a ReTestItems upgrade, check that the log's
# first `START (  1/...)` line is the sweeps' item, on worker 1. NWORKERS keeps the test workers, the analysis
# workers and this process within 8 vCPUs and the 16 GB of the CI runner.
using JETSweep, ReTestItems

const NWORKERS = 3   # measured at 2, 3, 4 and 6: see the report
# Under coverage, each worker writes its tracefile after every item (`<template>-items.info`): ReTestItems kills a
# worker right after its last item, often before its exit-time write. A no-op without coverage.
const WRITE_COVERAGE = :(let out = Base.JLOptions().output_code_coverage
    out == C_NULL || ccall(:jl_write_coverage_data, Cvoid, (Cstring,),
                           replace(unsafe_string(out), r"\.info$" => "-items.info"))
end)
const FILES = filter(endswith("_tests.jl"), readdir(@__DIR__))
const SELECTED = isempty(ARGS) ? FILES : ARGS
all(in(FILES), SELECTED) || error("unknown test files: $(join(setdiff(SELECTED, FILES), ", "))")

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

paths = isempty(ARGS) ? [@__DIR__] : [joinpath(@__DIR__, file) for file in ARGS]
# (No full garbage collection after each item: these workers' heaps are large, and measured side by side, the runs
# without it were faster.) The item timeout, 1200 s, is above the sweeps' own 900 s limit per unit, so a unit that
# hangs is reported by its sweep, and leaves the sweeps' item (about 300 s on 8 vCPUs) room on CI's 4 vCPUs.
ReTestItems.runtests(paths...; nworkers=NWORKERS, nworker_threads=1, retries=0, testitem_timeout=1200,
                     gc_between_testitems=false, test_end_expr=Expr(:block, WRITE_COVERAGE),
                     worker_init_expr=:(const MAIN_CHECK_BOUNDS = $(Base.JLOptions().check_bounds);
                                        const MAIN_DEPWARN = $(Base.JLOptions().depwarn);
                                        const MAIN_PATHOF = $(pathof(JETSweep));
                                        const ANALYZER_READY = $ANALYZER_READY))
