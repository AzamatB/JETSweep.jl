using JETSweep, Test

# `Pkg.test(test_args=["test_planning.jl"])` runs a selection.
const TEST_FILES = ["test_execution.jl", "test_integration.jl", "test_environments.jl", "test_discovery.jl",
                    "test_syntax.jl", "test_planning.jl"]
const SELECTED = isempty(ARGS) ? TEST_FILES : ARGS
all(in(TEST_FILES), SELECTED) || error("unknown test files: $(join(setdiff(SELECTED, TEST_FILES), ", "))")

# Workers load the analyzer compiled with Julia's default code generation flags and JETLS's
# development mode, as prepared environments have it. Precompile one such environment while
# test_execution.jl runs: the sweeps would otherwise compile it once per environment they
# prepare at the same time, and the preparations in depots of their own again.
analyzer = if any(in(SELECTED), ("test_environments.jl", "test_integration.jl"))
    environment = JETSweep.prepare(JETSweep.Context("", "", false, Dict{String,String}()), mktempdir())
    JETSweep.ready(environment) || error("cannot prepare an analysis environment: ", environment.message)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    command = `$julia --startup-file=no --project=$(environment.dir) -e 'using Pkg; Pkg.precompile()'`
    run(addenv(command, "JULIA_LOAD_PATH" => "@:@stdlib"); wait=false)
end

@testset "JETSweep" begin
    # test_execution.jl checks state that every worker of this process shares, so it runs alone.
    # The other files mostly wait for workers and other processes, so they run side by side.
    "test_execution.jl" in SELECTED && @testset "test_execution.jl" include("test_execution.jl")
    @sync for file in filter(!=("test_execution.jl"), SELECTED)
        @async begin
            file in ("test_environments.jl", "test_integration.jl") && wait(analyzer)
            @testset "$file" include(joinpath(@__DIR__, file))
        end
    end
end
