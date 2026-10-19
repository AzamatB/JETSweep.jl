using Test
using BackendWitness
helper_number() = 2
include("test_helpers.jl")

@testset "functional campaign must not be run by header extraction" begin
    write(joinpath(@__DIR__, "CAMPAIGN_RAN"), "unexpected")
    include("test_case.jl")
end
