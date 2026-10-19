using Test, JETSweep, TOML

@testset "Worker process lifecycle" begin
    mktempdir() do directory
        active = Set{Base.Process}()
        log = joinpath(directory, "worker.log")
        command = Cmd(`$(Base.julia_cmd()) --startup-file=no -e 'println("worker output"); exit(7)'`; detach=true)
        result = JETSweep._run_process(command, log, 30.0, active)
        @test result.exit_code == 7
        @test !result.timed_out
        @test isempty(active)
        @test occursin("worker output", read(log, String))
        command = Cmd(`$(Base.julia_cmd()) --startup-file=no -e 'sleep(60)'`; detach=true)
        result = JETSweep._run_process(command, log, 0.3, active)
        @test result.timed_out
        @test result.seconds < 10
        @test isempty(active)
    end
end

@testset "Bounded parallel scheduling" begin
    active = Set{Base.Process}()
    concurrent = Ref(0)
    peak = Ref(0)
    result = JETSweep._parallel_map(collect(1:9), 3, active) do value, _
        concurrent[] += 1
        peak[] = max(peak[], concurrent[])
        sleep(0.01)
        concurrent[] -= 1
        value^2
    end
    @test peak[] == 3
    @test result == collect(1:9).^2
    @test concurrent[] == 0
    started = time()
    @test_throws CapturedException JETSweep._parallel_map([1, 2], 2, active) do value, _
        value == 2 && error("later worker failed")
        sleep(10)
    end
    @test time() - started < 3
end

@testset "Structured worker protocol round trip" begin
    job = JETSweep.AnalysisJob(id="round-trip", kind=:test, entry="/workspace/test/x.jl",
        project="/workspace/Project.toml", owner="/workspace",
        expected_files=["/workspace/test/x.jl"],
        context=JETSweep.ContextSpec(arguments=["a b", "c"], variables=Dict("EXAMPLE" => "value"),
            containing_files=["/workspace/test/helper.jl"]))
    mktempdir() do directory
        path = joinpath(directory, "job.toml")
        JETSweep.write_toml(path, Dict("job" => JETSweep.job_dict(job)))
        reread = JETSweep.job_from_dict(TOML.parsefile(path)["job"])
        @test JETSweep.job_dict(reread) == JETSweep.job_dict(job)
        @test readdir(directory) == ["job.toml"]
    end
end

@testset "Incomplete results cannot pass severity filtering" begin
    inventory = JETSweep.Inventory("/workspace", JETSweep.ProjectRecord[], JETSweep.SourceRecord[], String[], String[])
    clean = Dict("full_analysis_complete" => true, "diagnostics" => [])
    hints = Dict("full_analysis_complete" => true, "diagnostics" => [Dict("severity" => 4)])
    incomplete = Dict("full_analysis_complete" => false, "diagnostics" => [])
    @test JETSweep._exit_code([clean], inventory, String[], :hint) == 0
    @test JETSweep._exit_code([hints], inventory, String[], :hint) == 1
    @test JETSweep._exit_code([hints], inventory, String[], :error) == 0
    @test JETSweep._exit_code([incomplete], inventory, String[], :none) == 2
    @test JETSweep._exit_code([clean], inventory, ["changed.jl"], :none) == 2
    owned = JETSweep.Inventory("/workspace", JETSweep.ProjectRecord[],
        [JETSweep.SourceRecord(path="/workspace/missing.jl")], String[], String[])
    @test JETSweep._exit_code([clean], owned, String[], :none) == 2
end

@testset "Malformed worker payloads retain an aggregate report" begin
    mktempdir() do directory
        file = joinpath(directory, "input.jl")
        write(file, "identity(x) = x\n")
        job = JETSweep.AnalysisJob(id="malformed", kind=:script, entry=file,
            project="", expected_files=[file])
        result = Dict{String,Any}("schema_version" => 1, "original_file" => file,
            "status" => "clean", "full_analysis_complete" => true,
            "analyzed_files" => [file], "diagnostics" => [1])
        JETSweep._validate_worker_result!(result, job)
        @test !result["full_analysis_complete"]
        @test result["status"] == "analysis_incomplete"
        @test isempty(result["diagnostics"])
        @test result["malformed_diagnostics"] == "[1]"
        report = JETSweep.SweepResult(directory, directory, discover(directory), [job],
            [result], "start", "end", String[], 2)
        JETSweep.write_report(report; io=devnull)
        @test TOML.parsefile(joinpath(directory, "report.toml"))["status"] == "incomplete"
        @test occursin("Malformed diagnostic records", read(joinpath(directory, "summary.txt"), String))
        missing = Dict{String,Any}("schema_version" => 1, "original_file" => file,
            "status" => "clean", "full_analysis_complete" => true,
            "analyzed_files" => String[], "diagnostics" => [])
        JETSweep._validate_worker_result!(missing, job)
        @test !missing["full_analysis_complete"]
    end
end
