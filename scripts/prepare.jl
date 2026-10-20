# JETSweep environment worker: prepares one analysis environment and writes its outcome.
#
#     julia --project=TOOL prepare.jl REQUEST.toml RESULT.toml
#
# The outcome is written before precompilation too, since workers can use the environment
# without package images: an environment whose precompilation runs out of time stays usable.
using JETSweep, TOML

# Preparations run side by side and share the depot's Git clones.
JETSweep.lock_clones!()
request = TOML.parsefile(ARGS[1])
context = JETSweep.Context(request["project"], request["owner"], request["test"],
                           Dict{String,String}(request["triggers"]), Dict{String,String}(request["imports"]))
environment = JETSweep.prepare(context, request["directory"]; instantiate=request["instantiate"])
outcome(message) = JETSweep._write_toml(ARGS[2], Dict("status" => String(environment.status),
                                                       "dir" => environment.dir, "message" => message))
outcome(environment.message)
if JETSweep.ready(environment)
    note = JETSweep.precompile_environment(environment.dir)
    isempty(note) || outcome(strip(environment.message * " " * note))
end
