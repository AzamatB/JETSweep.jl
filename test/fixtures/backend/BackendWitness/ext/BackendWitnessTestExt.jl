module BackendWitnessTestExt
using BackendWitness
using Test
extension_failure(x::Int) = sin("extension failure") + x
include("extension_helper.jl")
end
