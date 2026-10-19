include("helper.jl")

script_failure(x::Int) = sin(helper_label()) + x
script_failure(1)
