begin
    const helper_directory = joinpath(@__DIR__, "context")
    containing_helper() = "containing helper failure"
end
include(joinpath(helper_directory, "child.jl"))
