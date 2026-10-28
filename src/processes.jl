# Worker processes. Each runs detached in its own process group, so a timeout or an
# interrupt terminates it together with every process it started.

_group_alive(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), -pid, 0) == 0
_signal(pid::Integer, number::Integer) = _group_alive(pid) && ccall(:kill, Cint, (Cint, Cint), -pid, number)

function _terminate(process::Base.Process, pid::Integer)
    if Sys.isunix()
        _signal(pid, Base.SIGTERM)
        try
            timedwait(() -> !_group_alive(pid), 5.0; pollint=0.05)
        finally
            _signal(pid, Base.SIGKILL)
        end
    else
        process_exited(process) || kill(process)
    end
    wait(process)
    return nothing
end

"Processes started by `run_worker` that are still running, so an interrupt can stop them."
const _ACTIVE = Dict{Int,Base.Process}()
const _ACTIVE_LOCK = ReentrantLock()

"""
Run `command` with output appended to `log`. Returns the exit code (128 + signal when
signalled) and whether the time limit of `timeout` seconds (0 = none) expired. An interrupt
only signals the worker, leaving the rest to `_terminate_all`, so that it propagates at once.
"""
function run_worker(command::Cmd, log::String, timeout::Float64)
    open(log, "a") do io
        process = run(pipeline(Cmd(command; detach=true); stdin=devnull, stdout=io, stderr=io); wait=false)
        pid = getpid(process)
        @lock _ACTIVE_LOCK _ACTIVE[pid] = process
        timed_out = false
        try
            if timeout > 0
                timed_out = timedwait(() -> process_exited(process), timeout; pollint=0.1) === :timed_out
            else
                wait(process)
            end
        catch err
            err isa InterruptException && Sys.isunix() && (_signal(pid, Base.SIGTERM); rethrow())
            _terminate(process, pid)
            @lock _ACTIVE_LOCK delete!(_ACTIVE, pid)
            rethrow()
        end
        # The leader may exit before its children; always reap the whole group.
        _terminate(process, pid)
        @lock _ACTIVE_LOCK delete!(_ACTIVE, pid)
        code = process.termsignal == 0 ? process.exitcode : 128 + process.termsignal
        return (; code, timed_out)
    end
end

function _terminate_all()
    processes = @lock _ACTIVE_LOCK collect(_ACTIVE)
    Sys.isunix() || return foreach(((pid, process),) -> _terminate(process, pid), processes)
    # Signal every group, give them five seconds together, then kill what is left, even if
    # another interrupt cuts the wait short.
    foreach(((pid, _),) -> _signal(pid, Base.SIGTERM), processes)
    try
        timedwait(() -> !any(((pid, _),) -> _group_alive(pid), processes), 5.0; pollint=0.05)
    finally
        foreach(((pid, _),) -> _signal(pid, Base.SIGKILL), processes)
        foreach(((_, process),) -> wait(process), processes)
        @lock _ACTIVE_LOCK foreach(((pid, _),) -> delete!(_ACTIVE, pid), processes)
    end
end

"""
The worker Julia command. Workers use Julia's default code generation flags, whatever this
process runs with (`--check-bounds=yes` under `Pkg.test`, say), so they share the package
images of ordinary sessions and analyze code as it normally runs. With `compile=false` a
worker uses existing package images only, loading a package from source otherwise, since
environment preparation already precompiled what can be. Workers have no interactive
thread, so each runs exactly `threads` threads.
"""
function julia_command(script::String, args::Vector{String}; project::String, threads::Int,
                       compile::Bool=true, env::Dict{String,String}=Dict{String,String}())
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    modules = compile ? "yes" : "existing"
    command = `$julia --startup-file=no --history-file=no --compiled-modules=$modules --threads=$threads,0
               --project=$project $script $args`
    variables = merge(Dict(ENV), Dict(
        "JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        "OPENBLAS_NUM_THREADS" => "1", "OMP_NUM_THREADS" => "1", "JULIA_NUM_PRECOMPILE_TASKS" => "4"))
    merge!(variables, env)
    delete!(variables, "JULIA_PROJECT")
    return setenv(command, variables)
end
