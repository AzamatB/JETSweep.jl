_timestamp() = string(Dates.now(Dates.UTC)) * "Z"

function _stop_process(process::Base.Process, process_id::Union{Nothing,Integer}=nothing)
    if process_id === nothing
        process_exited(process) && return
        process_id = getpid(process)
    end
    if Sys.isunix()
        # Every worker owns a process group, including its compiler/analysis children.
        # The leader can exit before its descendants, so retain its PID at spawn
        # and test the group itself throughout the grace period.
        group_alive() = ccall(:kill, Cint, (Cint, Cint), -process_id, 0) == 0
        if group_alive()
            ccall(:kill, Cint, (Cint, Cint), -process_id, Base.SIGTERM)
            timedwait(() -> !group_alive(), 3.0; pollint=0.05)
            group_alive() && ccall(:kill, Cint, (Cint, Cint), -process_id, Base.SIGKILL)
        end
    else
        kill(process, Base.SIGTERM)
        timedwait(() -> process_exited(process), 3.0; pollint=0.05)
        process_exited(process) || kill(process, Base.SIGKILL)
    end
    wait(process)
    return
end

function _run_process(command::Cmd, log_path::String, timeout::Float64,
                      active::Set{Base.Process})
    started = time_ns()
    return open(log_path, "w") do log
        process = run(pipeline(Cmd(command; detach=true); stdout=log, stderr=log); wait=false)
        process_id = getpid(process)
        push!(active, process)
        timed_out = false
        stopped = false
        try
            if timeout > 0
                timed_out = timedwait(() -> process_exited(process), timeout; pollint=0.1) === :timed_out
                if timed_out
                    _stop_process(process, process_id)
                    stopped = true
                end
            end
            wait(process)
        finally
            try
                stopped || _stop_process(process, process_id)
            finally
                delete!(active, process)
            end
        end
        # Julia can report exitcode == 0 for a signal-terminated process.
        exit_code = process.termsignal == 0 ? process.exitcode : 128 + process.termsignal
        return (; exit_code, timed_out, signal=process.termsignal,
                seconds=(time_ns() - started) / 1.0e9)
    end
end

function _parallel_map(function_, items::Vector, width::Int, active::Set{Base.Process})
    isempty(items) && return Any[]
    queue = Channel{Int}(length(items))
    foreach(index -> put!(queue, index), eachindex(items))
    close(queue)
    results = Vector{Any}(undef, length(items))
    completions = Channel{Union{Nothing,CapturedException}}(min(width, length(items)))
    tasks = Task[]
    for _ in 1:min(width, length(items))
        push!(tasks, @async begin
            outcome = nothing
            try
                for index in queue
                    results[index] = function_(items[index], index)
                end
            catch error
                outcome = CapturedException(error, catch_backtrace())
            end
            put!(completions, outcome)
        end)
    end
    try
        for _ in tasks
            outcome = take!(completions)
            outcome === nothing || throw(outcome)
        end
    catch
        foreach(_stop_process, collect(active))
        for task in tasks
            istaskdone(task) || schedule(task, InterruptException(); error=true)
        end
        rethrow()
    end
    return results
end

_canonical_file(path::AbstractString) = ispath(path) ? realpath(path) : abspath(path)

function _validate_worker_result!(result::Dict{String,Any}, job::AnalysisJob)
    errors = String[]
    get(result, "schema_version", 0) == 1 || push!(errors, "Unsupported or missing worker result schema")
    original = get(result, "original_file", "")
    original isa AbstractString && _canonical_file(original) == _canonical_file(job.entry) ||
        push!(errors, "Worker result does not identify the requested original source")
    files = get(result, "analyzed_files", Any[])
    valid_files = files isa AbstractVector && all(path -> path isa AbstractString, files)
    valid_files || push!(errors, "Malformed analyzed-file list")
    rows = get(result, "diagnostics", Any[])
    valid_rows = rows isa AbstractVector && all(row -> row isa AbstractDict &&
        get(row, "severity", 0) in 1:4 && get(row, "file", nothing) isa AbstractString &&
        get(row, "message", nothing) isa AbstractString &&
        get(row, "line", 0) isa Integer && get(row, "column", 0) isa Integer, rows)
    valid_rows || push!(errors, "Malformed diagnostic records")
    if get(result, "full_analysis_complete", false)
        get(result, "status", "") in ("clean", "findings") ||
            push!(errors, "Worker completion flag contradicts its status")
        covered = valid_files ? Set(_canonical_file.(files)) : Set{String}()
        missing = filter(path -> _canonical_file(path) ∉ covered, job.expected_files)
        isempty(missing) || push!(errors, "Worker omitted expected original files: " * join(missing, ", "))
    end
    if !isempty(errors)
        result["protocol_errors"] = errors
        result["status"] = "analysis_incomplete"
        result["full_analysis_complete"] = false
    end
    if !valid_files
        result["malformed_analyzed_files"] = repr(files)
        result["analyzed_files"] = String[]
    end
    if !valid_rows
        result["malformed_diagnostics"] = repr(rows)
        result["diagnostics"] = Dict{String,Any}[]
    end
    # Metadata identifying the job belongs to the coordinator.
    result["job_id"] = job.id
    result["kind"] = String(job.kind)
    result["entry"] = job.entry
    result["expected_files"] = job.expected_files
    return result
end

function _gpu_devices(requested::Vector{String})
    requested == ["none"] && return [""]
    !isempty(requested) && requested != ["auto"] && return requested
    if haskey(ENV, "CUDA_VISIBLE_DEVICES")
        visible = strip(ENV["CUDA_VISIBLE_DEVICES"])
        return isempty(visible) || visible == "-1" ? [""] : strip.(split(visible, ','))
    end
    tool = Sys.which("nvidia-smi")
    tool === nothing && return String[]
    try
        return filter(!isempty, strip.(readlines(`$tool --query-gpu=uuid --format=csv,noheader`)))
    catch
        return String[]
    end
end

function _worker_command(script::String, arguments::Vector{String}, options::SweepOptions;
                         variables::Dict{String,String}=Dict{String,String}(), gpu::Union{Nothing,String}=nothing,
                         project::String=_tool_project())
    isempty(project) && error("JETSweep could not locate its resolved tool environment")
    project_directory = isdir(project) ? project : dirname(project)
    julia = Base.julia_cmd()
    command = `$julia --startup-file=no --history-file=no --compiled-modules=existing --threads=$(options.threads),1 --project=$project_directory $script $arguments`
    environment = merge(copy(ENV), Dict(
        "JULIA_PKG_PRECOMPILE_AUTO" => "0", "JULIA_LOAD_PATH" => "@:@stdlib",
        "OPENBLAS_NUM_THREADS" => "1", "OMP_NUM_THREADS" => "1"), variables)
    gpu === nothing || (environment["CUDA_VISIBLE_DEVICES"] = gpu)
    return setenv(Cmd(command; detach=true), environment)
end

function _prepare(job::AnalysisJob, key::String, output::String, options::SweepOptions, active)
    directory = joinpath(output, "environments", key)
    mkpath(directory)
    request = joinpath(directory, "request.toml")
    result_path = joinpath(directory, "result.toml")
    write_toml(request, Dict("job" => job_dict(job), "instantiate" => options.instantiate))
    command = _worker_command(joinpath(dirname(@__DIR__), "scripts", "prepare_environment.jl"),
        [request, joinpath(directory, "project"), result_path], options)
    write_toml(joinpath(directory, "execution.toml"), Dict(
        "command" => copy(command.exec), "timeout" => options.timeout))
    log = joinpath(directory, "raw.log")
    try
        process = _run_process(command, log, options.timeout, active)
        result = isfile(result_path) ? environment_from_dict(TOML.parsefile(result_path)) :
            EnvironmentResult(status=:failed, message="Environment worker did not write a result; see $log")
        if process.timed_out || process.exit_code != 0
            reason = process.timed_out ? "Environment preparation timed out" : "Environment worker exited $(process.exit_code)"
            return EnvironmentResult(status=:failed, message="$reason: $(result.message); see $log")
        end
        return result
    catch error
        error isa InterruptException && rethrow()
        return EnvironmentResult(status=:failed, message=sprint(showerror, error))
    end
end

function _merge_configuration!(destination::Dict{String,Any}, source::AbstractDict)
    for (key, value) in source
        if value isa AbstractDict && get(destination, key, nothing) isa AbstractDict
            _merge_configuration!(destination[key], value)
        else
            destination[key] = deepcopy(value)
        end
    end
    return destination
end

function _write_analysis_configuration(job::AnalysisJob, directory::String)
    configuration = Dict{String,Any}(
        "full_analysis" => Dict{String,Any}("auto_instantiate" => "never", "concretization_timeout" => 120.0),
        "diagnostic" => Dict{String,Any}("enabled" => true, "all_files" => true, "patterns" => String[]),
        "initialization_options" => Dict{String,Any}("reuse_native_inference" => false))
    isempty(job.context.configuration) ||
        _merge_configuration!(configuration, TOML.parsefile(job.context.configuration))
    full = configuration["full_analysis"]
    diagnostic = configuration["diagnostic"]
    initialization = configuration["initialization_options"]
    all(section -> section isa AbstractDict, (full, diagnostic, initialization)) ||
        throw(ArgumentError("JETLS configuration sections must be tables"))
    get(full, "auto_instantiate", "never") == "never" ||
        throw(ArgumentError("JETSweep manages dependency preparation; JETLS auto_instantiate must be never"))
    get(diagnostic, "enabled", true) === true && get(diagnostic, "all_files", true) === true &&
        get(diagnostic, "patterns", []) isa AbstractVector && isempty(get(diagnostic, "patterns", [])) ||
        throw(ArgumentError("JETSweep retains unfiltered diagnostics; enabled/all_files must be true and patterns empty"))
    get(initialization, "reuse_native_inference", false) === false ||
        throw(ArgumentError("JETSweep requires fresh analysis; reuse_native_inference must be false"))
    return write_toml(joinpath(directory, ".JETLSConfig.toml"), configuration)
end

function _source_fallbacks(jobs::Vector{AnalysisJob}, results, inventory::Inventory)
    direct = Set(job.entry for job in jobs)
    covered = Set{String}()
    for result in results
        get(result, "full_analysis_complete", false) &&
            union!(covered, _canonical_file.(get(result, "analyzed_files", String[])))
    end
    owned = Dict(file.path => file for file in inventory.files)
    fallbacks = Pair{String,AnalysisJob}[]
    for (job, result) in zip(jobs, results)
        job.kind in (:package, :extension) || continue
        for file in job.expected_files
            file in direct && continue
            _canonical_file(file) in covered && continue
            haskey(owned, file) || continue
            isfile(file) || continue
            context = job.context
            fallback = AnalysisJob(id=_job_id(:source, file, inventory.root), kind=:source,
                entry=file, project=job.project, owner=job.owner, expected_files=[file],
                context=ContextSpec(project=context.project, setup=context.setup,
                    arguments=context.arguments, variables=context.variables,
                    configuration=context.configuration),
                issues=["The package or extension run did not establish coverage for this file; this supplemental source context imports its owner exports and does not reconstruct an inactive internal include site."])
            push!(fallbacks, job.id => fallback)
            push!(direct, file)
        end
    end
    return fallbacks
end

function _analyze(job::AnalysisJob, environment::EnvironmentResult, root::String,
                  output::String, options::SweepOptions, active, gpu, io::IO)
    directory = joinpath(output, "jobs", job.id)
    mkpath(directory)
    result_path = joinpath(directory, "result.toml")
    result = Dict{String,Any}("job_id" => job.id, "kind" => String(job.kind),
        "entry" => job.entry, "expected_files" => job.expected_files,
        "started" => _timestamp(), "full_analysis_complete" => false,
        "diagnostics" => Dict{String,Any}[], "analyzed_files" => String[])
    configuration_ok = true
    try
        _write_analysis_configuration(job, joinpath(directory, "config"))
    catch error
        error isa InterruptException && rethrow()
        configuration_ok = false
        merge!(result, Dict("status" => "invalid_configuration", "error" => sprint(showerror, error)))
    end
    raw_log = joinpath(directory, "raw.log")
    if !configuration_ok
        write(raw_log, result["error"], '\n')
    elseif environment.status !== :ready
        merge!(result, Dict("status" => "environment_unavailable", "error" => environment.message))
        write(raw_log, environment.message, '\n')
    else
        request = joinpath(directory, "job.toml")
        write_toml(request, Dict("schema_version" => 1, "root" => root,
            "config_directory" => joinpath(directory, "config"),
            "environment_project" => environment.project, "load_paths" => environment.load_paths,
            "job" => job_dict(job)))
        command = _worker_command(joinpath(dirname(@__DIR__), "scripts", "analyze.jl"),
            [request, result_path], options; variables=job.context.variables, gpu,
            project=isempty(environment.tool_project) ? _tool_project() : environment.tool_project)
        result["command"] = copy(command.exec)
        result["timeout"] = options.timeout
        try
            process = _run_process(command, joinpath(directory, "raw.log"), options.timeout, active)
            if isfile(result_path)
                merge!(result, TOML.parsefile(result_path))
                _validate_worker_result!(result, job)
            else
                merge!(result, Dict("status" => "analysis_incomplete", "error" => "Worker did not write an analysis result"))
            end
            result["seconds"] = process.seconds
            result["exit_code"] = process.exit_code
            if process.timed_out
                result["status"] = "timeout"
                result["full_analysis_complete"] = false
            elseif process.exit_code != 0
                result["full_analysis_complete"] = false
                get(result, "status", "") in ("clean", "findings") && (result["status"] = "analysis_incomplete")
            end
        catch error
            error isa InterruptException && rethrow()
            merge!(result, Dict("status" => "worker_error", "error" => sprint(showerror, error),
                                "full_analysis_complete" => false))
        end
    end
    result["finished"] = _timestamp()
    result["log"] = joinpath(directory, "raw.log")
    result["environment"] = environment.project
    result["tool_environment"] = environment.tool_project
    gpu === nothing || (result["gpu"] = gpu)
    write_toml(result_path, result)
    println(io, "[", result["status"], "] ", relpath(job.entry, root),
            isempty(job.extension) ? "" : " ($(job.extension))")
    flush(io)
    return result
end

const _SEVERITY = Dict(:error => 1, :warning => 2, :warn => 2, :info => 3, :hint => 4, :none => 0)

function _exit_code(results, inventory::Inventory, changes, severity::Symbol)
    (!isempty(inventory.issues) || !isempty(changes) ||
     any(result -> !get(result, "full_analysis_complete", false), results)) && return 2
    covered = Set{String}()
    for result in results
        union!(covered, _canonical_file.(get(result, "analyzed_files", String[])))
    end
    any(file -> _canonical_file(file.path) ∉ covered, inventory.files) && return 2
    threshold = _SEVERITY[severity]
    any(result -> any(d -> 0 < get(d, "severity", 1) <= threshold,
                      get(result, "diagnostics", [])), results) && return 1
    return 0
end

"Recursively analyze a directory, retaining every job result and incomplete context."
function sweep(root::AbstractString; options::SweepOptions=SweepOptions(), io::IO=stderr)
    options.jobs > 0 || throw(ArgumentError("jobs must be positive"))
    options.threads > 0 || throw(ArgumentError("threads must be positive"))
    options.timeout >= 0 || throw(ArgumentError("timeout must be nonnegative"))
    haskey(_SEVERITY, options.fail_severity) || throw(ArgumentError("invalid failure severity"))
    root = abspath(root)
    isdir(root) || throw(ArgumentError("directory does not exist: $root"))
    run_id = Dates.format(Dates.now(Dates.UTC), "yyyymmdd-HHMMSS") * "-" * string(uuid4())[1:8]
    output = isempty(options.output) ? joinpath(root, ".jetsweep", run_id) : abspath(options.output)
    ispath(output) && (!isdir(output) || !isempty(readdir(output))) &&
        throw(ArgumentError("output must be a new or empty directory: $output"))
    inventory = discover(root; excludes=options.excludes, output,
        include_ignored=options.include_ignored, include_untracked=options.include_untracked)
    jobs = plan(inventory; config=options.config)
    started = _timestamp()
    before = input_snapshot(inventory, jobs; config=options.config)
    mkpath(output)
    write_toml(joinpath(output, "inventory.toml"), inventory_dict(inventory))
    write_toml(joinpath(output, "plan.toml"), Dict("schema_version" => 1,
        "jobs" => job_dict.(jobs), "execution" => Dict(
            "workers" => options.jobs, "threads_per_worker" => options.threads,
            "timeout_seconds" => options.timeout, "requested_gpus" => options.gpu_devices,
            "instantiate" => options.instantiate, "fail_severity" => String(options.fail_severity),
            "include_ignored" => options.include_ignored, "include_untracked" => options.include_untracked,
            "excludes" => options.excludes, "context_config" => options.config,
            "julia_version" => string(VERSION), "tool_project" => _tool_project())))
    write_toml(joinpath(output, "inputs-before.toml"), Dict("files" => before))
    println(io, "JETSweep: $(length(inventory.files)) files, $(count(p -> !isempty(p.entry), inventory.projects)) packages, $(length(jobs)) jobs")
    if options.plan_only
        println(io, "Plan written to $output; no analysis processes started")
        return SweepResult(root, output, inventory, jobs, Dict{String,Any}[], started,
            _timestamp(), String[], isempty(inventory.issues) ? 0 : 2)
    end
    active = Set{Base.Process}()
    representatives = Dict{String,AnalysisJob}()
    keys_by_identity = Dict{Tuple{Symbol,String,String,String,Tuple},String}()
    keys_by_job = Dict{String,String}()
    for job in jobs
        identity = (job.kind, job.project, job.owner, job.context.project,
                    Tuple(sort!(collect(job.triggers); by=first)))
        key = get!(keys_by_identity, identity) do
            environment_key(job)
        end
        keys_by_job[job.id] = key
        get!(representatives, key, job)
    end
    requests = sort!(collect(representatives); by=first)
    println(io, "Preparing $(length(requests)) isolated environments with $(options.jobs) parallel workers")
    prepared = _parallel_map(requests, options.jobs, active) do request, _
        _prepare(last(request), first(request), output, options, active)
    end
    environments = Dict(first(request) => environment for (request, environment) in zip(requests, prepared))
    devices = _gpu_devices(options.gpu_devices)
    results = _parallel_map(jobs, options.jobs, active) do job, index
        gpu = isempty(devices) ? nothing : devices[mod1(index, length(devices))]
        _analyze(job, environments[keys_by_job[job.id]], inventory.root, output, options, active, gpu, io)
    end
    fallbacks = _source_fallbacks(jobs, results, inventory)
    if !isempty(fallbacks)
        println(io, "Analyzing $(length(fallbacks)) sources not covered by their package/extension context")
        write_toml(joinpath(output, "supplemental-plan.toml"), Dict("jobs" => [
            merge(job_dict(last(fallback)), Dict("parent_job" => first(fallback))) for fallback in fallbacks]))
        supplemental = _parallel_map(fallbacks, options.jobs, active) do fallback, index
            parent_id, job = fallback
            gpu = isempty(devices) ? nothing : devices[mod1(index, length(devices))]
            result = _analyze(job, environments[keys_by_job[parent_id]], inventory.root, output, options, active, gpu, io)
            result["supplemental_parent_job"] = parent_id
            write_toml(joinpath(output, "jobs", job.id, "result.toml"), result)
            result
        end
        append!(jobs, last.(fallbacks))
        append!(results, supplemental)
    end
    after_inventory = discover(root; excludes=options.excludes, output,
        include_ignored=options.include_ignored, include_untracked=options.include_untracked)
    after = input_snapshot(after_inventory, jobs; config=options.config)
    changes = changed_inputs(before, after)
    for environment in values(environments), (path, digest) in environment.fingerprints
        (!isfile(path) || file_digest(path) != digest) && push!(changes, path)
    end
    sort!(unique!(changes))
    write_toml(joinpath(output, "inputs-after.toml"), Dict("files" => after))
    completed = Dict{String,Any}[result for result in results]
    report = SweepResult(inventory.root, output, inventory, jobs, completed, started,
        _timestamp(), changes, _exit_code(completed, inventory, changes, options.fail_severity))
    write_report(report; io)
    return report
end
