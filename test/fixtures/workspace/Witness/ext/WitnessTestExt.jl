module WitnessTestExt

using Witness
using Test

extension_failure(x::Int) = sin("extension failure") + x

include("helper.jl")

end
