module WitnessTestExt

using Witness
using Test

extension_failure(x::Int) = sin("extension failure") + x

include("helper.jl")

if false
    include("dormant.jl")
end

end
