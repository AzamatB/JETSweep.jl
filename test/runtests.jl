using Test, JETSweep

const TEST_FILES = ["test_discovery.jl", "test_syntax.jl", "test_planning.jl", "test_environments.jl",
                    "test_execution.jl", "test_integration.jl"]
const SELECTED = isempty(ARGS) ? TEST_FILES : ARGS
all(in(TEST_FILES), SELECTED) || error("unknown test files: $(join(setdiff(SELECTED, TEST_FILES), ", "))")

@testset "JETSweep" begin
    for file in SELECTED
        @testset "$file" include(file)
    end
end
