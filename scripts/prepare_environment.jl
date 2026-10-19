using JETSweep
using TOML

length(ARGS) == 3 || error("usage: prepare_environment.jl JOB.toml DIRECTORY RESULT.toml")
request = TOML.parsefile(ARGS[1])
job = JETSweep.job_from_dict(request["job"])
result = JETSweep.prepare_environment(job, ARGS[2]; instantiate=get(request, "instantiate", true))
if result.status === :ready
    result = JETSweep.prepare_tool_environment(result, joinpath(dirname(ARGS[2]), "tool");
        instantiate=get(request, "instantiate", true))
end
JETSweep.write_toml(ARGS[3], JETSweep.environment_dict(result))
exit(result.status === :ready ? 0 : 2)
