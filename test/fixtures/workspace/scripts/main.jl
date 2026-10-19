include("helper.jl")

script_failure(x::Int) = sin(helper_label()) + x
script_failure(1)

struct Point
    x::Int
end
point_failure(p::Point) = p.y
module MyMain
mymain_failure() = not_defined_in_mymain
end
wide_failure() = sin("é😀")
