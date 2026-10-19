module JETSweep

using Dates
using LibGit2
using Pkg
using SHA
using TOML
using UUIDs

const _LOADED_TOOL_PROJECT = Ref{String}("")

function __init__()
    _, environment = lock(Base.require_lock) do
        Base.locate_package_env(Base.PkgId(@__MODULE__))
    end
    _LOADED_TOOL_PROJECT[] = something(environment, joinpath(dirname(@__DIR__), "Project.toml"))
    return
end

_tool_project() = _LOADED_TOOL_PROJECT[]

include("model.jl")
include("io.jl")
include("discovery.jl")
include("planning.jl")
include("environments.jl")
include("tool_environment.jl")
include("execution.jl")
include("reporting.jl")
include("cli.jl")

export SweepOptions, discover, plan, sweep
public main

end # module JETSweep
