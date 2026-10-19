# JETSweep environment worker: prepares one analysis environment and writes its outcome.
#
#     julia --project=TOOL prepare.jl REQUEST.toml RESULT.toml
using JETSweep, TOML

request = TOML.parsefile(ARGS[1])
context = JETSweep.Context(request["project"], request["owner"], request["test"],
                           Dict{String,String}(request["triggers"]))
environment = JETSweep.prepare(context, request["directory"]; instantiate=request["instantiate"])
open(ARGS[2], "w") do io
    TOML.print(io, Dict("status" => String(environment.status), "dir" => environment.dir,
                        "message" => environment.message))
end
