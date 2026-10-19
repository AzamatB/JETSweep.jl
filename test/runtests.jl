using Test, JETSweep

const TEST_FILES = ["test_discovery.jl", "test_planning.jl", "test_environments.jl",
                    "test_tool_environment.jl", "test_execution.jl", "test_scheduler_review.jl", "test_cli.jl",
                    "test_backend.jl", "test_runtime_context.jl", "test_integration.jl"]
selected = isempty(ARGS) ? TEST_FILES : ARGS
all(name -> name in TEST_FILES, selected) || error("Unknown test selector: $(join(selected, ", "))")
@testset "JETSweep" begin
    for file in selected
        include(file)
    end
end
