module BackendWitness
export twice
twice(x::Int) = 2x
package_failure(x::Int) = sin("package failure") + x
include("nested.jl")
end
