#!/usr/bin/env julia
# Keep JETLS out of normal package loading and planning processes.
module JETSweepWorker

using JETSweep
using Logging

struct WorkerBootstrapLogger{L<:AbstractLogger} <: AbstractLogger
    delegate::L
    errors::Vector{String}
    lock::ReentrantLock
end
Logging.min_enabled_level(logger::WorkerBootstrapLogger) = min(Logging.Error,Logging.min_enabled_level(logger.delegate))
Logging.shouldlog(logger::WorkerBootstrapLogger,level,args...) = level >= Logging.Error || Logging.shouldlog(logger.delegate,level,args...)
Logging.catch_exceptions(::WorkerBootstrapLogger) = false
function Logging.handle_message(logger::WorkerBootstrapLogger,level,message,args...;kwargs...)
    if level >= Logging.Error
        lock(logger.lock) do
            push!(logger.errors,string(message," ",kwargs))
        end
    end
    Logging.handle_message(logger.delegate,level,message,args...;kwargs...)
end

function bootstrap(arguments)
    length(arguments) == 2 || error("usage: analyze.jl JOB.toml RESULT.toml")
    output = abspath(arguments[2])
    logger = WorkerBootstrapLogger(current_logger(),String[],ReentrantLock())
    try
        # The pinned release gates its Revise signature backend behind a
        # compile-time preference and requires TestRunner in the root environment.
        # Copy its resolved dependency graph into a worker-local overlay. Neither
        # the analyzed project nor the installed tool's preferences are modified.
        directory = joinpath(dirname(output),"backend-preferences")
        mkpath(directory)
        _, environment = lock(Base.require_lock) do
            Base.locate_package_env(Base.PkgId(JETSweep))
        end
        manifest = something(Base.project_file_manifest_path(environment))
        data = JETSweep.TOML.parsefile(manifest)
        for entries in values(get(data,"deps",Dict()))
            for entry in entries
                haskey(entry,"path") || continue
                entry["path"] = abspath(dirname(manifest),entry["path"])
            end
        end
        JETSweep.write_toml(joinpath(directory,"Manifest.toml"),data)
        JETSweep.write_toml(joinpath(directory,"Project.toml"),Dict(
            "deps"=>Dict("JETLSCore"=>"8d6afe4c-923b-5912-b63d-b990009c9e74",
                "TestRunner"=>"65a77010-ae58-5cc9-8243-71cff1cf0f92"),
            "preferences"=>Dict("JETLSCore"=>Dict("JETLS_DEV_MODE"=>true))))
        pushfirst!(LOAD_PATH,directory)
        with_logger(logger) do
            Base.include(JETSweep,joinpath(pkgdir(JETSweep),"src","backend.jl"))
        end
        return Base.invokelatest(() -> JETSweep.JETSweepBackend.main(arguments,logger.errors))
    catch exception
        result = Dict("schema_version"=>1,"status"=>"analysis_incomplete",
            "full_analysis_complete"=>false,"stage"=>"backend_bootstrap",
            "internal_errors"=>logger.errors,"error"=>sprint(showerror,exception,catch_backtrace()))
        JETSweep.write_toml(output,result)
        return 1
    end
end

end # module JETSweepWorker

if abspath(PROGRAM_FILE) == @__FILE__
    exit(JETSweepWorker.bootstrap(copy(ARGS)))
end
