using Test
using Witness

const SUITE = "witness"
helper_number() = 2
include("helpers.jl")

# Run-time selection, as `Pkg.test(test_args=[...])` uses it: analysis cannot evaluate it.
const TEST_FILES = ["dynamic.jl", "independent.jl"]
const SELECTED = isempty(ARGS) ? TEST_FILES : ARGS

@testset "Witness" begin
    @test twice(helper_number()) == 4
    for file in SELECTED
        include(file)
    end
end
