"""
Recursive JETLS analysis of every Julia package, extension, test and script below a
directory, with each analysis in its own process. See [`sweep`](@ref).
"""
module JETSweep

using Base: UUID
using LibGit2
using Pkg
using SHA
using TOML

include("model.jl")
include("discovery.jl")
include("syntax.jl")
include("config.jl")
include("planning.jl")
include("environments.jl")
include("processes.jl")
include("execution.jl")
include("reporting.jl")
include("cli.jl")

function __init__()
    _, environment = @lock Base.require_lock Base.locate_package_env(Base.PkgId(@__MODULE__))
    _LOADED_PROJECT[] = something(environment, joinpath(dirname(@__DIR__), "Project.toml"))
    return nothing
end

export SweepOptions, discover, plan, sweep
public main, read_config, prepare, prelude, parse_source

end # module JETSweep
