module BackendBrokenTestExt
using BackendBroken
using Test
error("Intentional extension load failure witness")
end
