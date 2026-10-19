include("nested.jl")
script_failure(x::Int) = sin("script failure") + x
script_failure(1)
