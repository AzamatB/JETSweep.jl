module BackendPrecompileWitness
if ccall(:jl_generating_output, Cint, ()) != 0
    write(joinpath(@__DIR__, "NATIVE_PRECOMPILE_RAN"), "precompile workload executed")
end
precompile_witness(x::Int) = x + 1
end
