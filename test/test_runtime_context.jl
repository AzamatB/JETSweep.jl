using Test, JETSweep, Pkg, TOML, UUIDs

function _runtime_context_package(root, name, body; version="1.0.0")
    directory = joinpath(root, name)
    mkpath(joinpath(directory, "src"))
    project = Dict{String,Any}("name" => name, "uuid" => string(uuid4()))
    version === nothing || (project["version"] = version)
    JETSweep.write_toml(joinpath(directory, "Project.toml"), project)
    entry = joinpath(directory, "src", name * ".jl")
    write(entry, "module $name\n$body\nend\n")
    job = JETSweep.AnalysisJob(id=name, kind=:package, project=directory,
        owner=directory, entry=entry, expected_files=[entry])
    return job, project["uuid"]
end

function _runtime_context_environment(job, directory)
    target = JETSweep.prepare_environment(job, joinpath(directory, "target"); instantiate=false)
    @test target.status === :ready
    target.status === :ready || error(target.message)
    environment = JETSweep.prepare_tool_environment(target, joinpath(directory, "tool"); instantiate=false)
    @test environment.status === :ready
    environment.status === :ready || error(environment.message)
    return environment
end

function _runtime_context_run(job, environment, directory)
    options = JETSweep.SweepOptions(jobs=1, threads=1, timeout=180.0,
        instantiate=false, gpu_devices=["none"], fail_severity=:none)
    result = JETSweep._analyze(job, environment, directory, joinpath(directory, "report"),
        options, Set{Base.Process}(), "", devnull)
    if !get(result, "full_analysis_complete", false)
        @info "Runtime context control" job.id status=result["status"] error=get(result, "error", "") log=result["log"]
    end
    return result
end

function _runtime_context_complete(result, environment)
    @test result["full_analysis_complete"]
    @test result["status"] in ("clean", "findings")
    @test isempty(result["internal_errors"])
    @test isempty(result["dependency_identity_conflicts"])
    @test isempty(result["preference_identity_conflicts"])
    @test isempty(result["changed_inputs"])
    @test result["active_project"] == joinpath(environment.project, "Project.toml")
    @test result["active_project_after_analysis"] == joinpath(environment.project, "Project.toml")
end

@testset "target initialization sees the prepared active project" begin
    mktempdir() do directory
        observed = joinpath(directory, "active-project.txt")
        body = """
        function __init__()
            write($(repr(observed)), something(Base.active_project(), "missing"))
        end
        value(x::Int) = x + 1
        """
        job, _ = _runtime_context_package(directory, "RuntimeActiveProject", body)
        environment = _runtime_context_environment(job, directory)
        result = _runtime_context_run(job, environment, directory)
        _runtime_context_complete(result, environment)
        @test isfile(observed)
        @test read(observed, String) == joinpath(environment.project, "Project.toml")
        @test result["active_project"] != JETSweep._tool_project()
    end
end

@testset "unversioned local packages retain exact source identity" begin
    mktempdir() do directory
        job, uuid = _runtime_context_package(directory, "RuntimeUnversioned",
            "planted_error() = sin(\"unversioned-method-error\")"; version=nothing)
        environment = _runtime_context_environment(job, directory)
        manifest = Pkg.Types.EnvCache(joinpath(environment.project, "Project.toml")).manifest
        @test manifest[UUID(uuid)].version == v"0.0.0"
        @test !haskey(TOML.parsefile(joinpath(job.owner, "Project.toml")), "version")
        result = _runtime_context_run(job, environment, directory)
        _runtime_context_complete(result, environment)
        @test any(row -> row["file"] == job.entry && row["code"] == "inference/method-error", result["diagnostics"])
        identity = only(filter(row -> row["uuid"] == uuid, result["dependency_identity_checks"]))
        @test identity["matches"]
        @test identity["expected_version"] == ""
        @test identity["actual_version"] == ""
        @test identity["expected_source"] == realpath(job.owner)
    end
end

function _runtime_context_core_job(directory, devmode)
    original = JETSweep._tool_project()
    baseline = Pkg.Types.EnvCache(original)
    project_directory = joinpath(directory, "declared-context")
    mkpath(project_directory)
    JETSweep.write_toml(joinpath(project_directory, "Project.toml"), Dict(
        "deps" => Dict("JETLSCore" => "8d6afe4c-923b-5912-b63d-b990009c9e74")))
    manifest = deepcopy(baseline.manifest)
    for entry in values(manifest)
        entry.path === nothing || (entry.path = abspath(dirname(baseline.manifest_file), entry.path))
    end
    Pkg.Types.write_manifest(manifest, joinpath(project_directory, "Manifest.toml"))
    JETSweep.write_toml(joinpath(project_directory, "LocalPreferences.toml"),
        Dict("JETLSCore" => Dict("JETLS_DEV_MODE" => devmode)))
    entry = joinpath(directory, "probe.jl")
    write(entry, "using JETLSCore\nconfigured_mode() = JETLSCore.JETLS_DEV_MODE\n")
    return JETSweep.AnalysisJob(id=devmode ? "matching-tool-preferences" : "conflicting-tool-preferences",
        kind=:script, project=project_directory, entry=entry, expected_files=[entry])
end

@testset "loaded shared preferences must match the target context" begin
    for matching in (true, false)
        mktempdir() do directory
            job = _runtime_context_core_job(directory, matching)
            environment = _runtime_context_environment(job, directory)
            result = _runtime_context_run(job, environment, directory)
            core_uuid = "8d6afe4c-923b-5912-b63d-b990009c9e74"
            rows = matching ? result["preference_identity_checks"] : result["preference_identity_conflicts"]
            row = only(filter(value -> value["uuid"] == core_uuid, rows))
            @test row["loaded_at_bootstrap"]
            @test row["loaded_preferences"]["JETLS_DEV_MODE"] === true
            @test row["target_preferences"]["JETLS_DEV_MODE"] === matching
            @test row["matches"] === matching
            if matching
                _runtime_context_complete(result, environment)
            else
                @test !result["full_analysis_complete"]
                @test result["status"] ∉ ("clean", "findings")
                @test !isempty(result["preference_identity_conflicts"])
                @test isempty(result["dependency_identity_conflicts"])
            end
        end
    end
end

@testset "runtime compatibility obeys the pinned backend bounds" begin
    mktempdir() do directory
        entry = joinpath(directory, "probe.jl")
        write(entry, "runtime_version_probe(x::Int) = x + 1\n")
        job = JETSweep.AnalysisJob(id="runtime-version-bounds", kind=:script,
            project="", entry=entry, expected_files=[entry])
        environment = _runtime_context_environment(job, directory)
        configuration = joinpath(directory, "config")
        JETSweep._write_analysis_configuration(job, configuration)
        request, output = joinpath(directory, "job.toml"), joinpath(directory, "analysis.toml")
        checks_file = joinpath(directory, "version-checks.toml")
        JETSweep.write_toml(request, Dict("schema_version" => 1, "root" => directory,
            "config_directory" => configuration, "environment_project" => environment.project,
            "load_paths" => environment.load_paths, "job" => JETSweep.job_dict(job)))
        harness = joinpath(directory, "version_harness.jl")
        write(harness, """
        using JETSweep
        include(joinpath(pkgdir(JETSweep), "scripts", "analyze.jl"))
        arguments = copy(ARGS)
        code = JETSweepWorker.bootstrap(arguments[1:2])
        code == 0 || exit(code)
        checks = Base.invokelatest() do
            backend = JETSweep.JETSweepBackend
            values = Dict{String,Bool}("current" => backend.validate_julia_version(VERSION) === nothing,
                "minimum" => backend.validate_julia_version(v"1.13.0") === nothing)
            for version in (v"1.12.99", v"1.14.0", v"2.0.0")
                values[string(version)] = try
                    backend.validate_julia_version(version)
                    false
                catch exception
                    exception isa backend.UnsupportedBackend
                end
            end
            values
        end
        JETSweep.write_toml(arguments[3], checks)
        """)
        command = JETSweep._worker_command(harness, [request, output, checks_file],
            JETSweep.SweepOptions(threads=1); project=environment.tool_project)
        process = JETSweep._run_process(command, joinpath(directory, "worker.log"), 180.0, Set{Base.Process}())
        @test process.exit_code == 0
        @test !process.timed_out
        @test isfile(checks_file)
        @test all(values(TOML.parsefile(checks_file)))
        @test TOML.parsefile(output)["full_analysis_complete"]
    end
end
