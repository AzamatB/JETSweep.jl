nested_failure(x::Int) = cos("nested failure") + x
# JETLS coverage must never be described as a proof of type stability.
mutable_values = Any[1]
unstable(x::Int) = mutable_values[1] + x
