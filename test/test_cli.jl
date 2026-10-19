using Test, JETSweep, TOML

@testset "CLI options" begin
    root, options = JETSweep._parse_cli(["--jobs=3", "--threads", "2", "--gpus", "0,2",
        "--exclude", "generated/**", "--no-instantiate", "--tracked-only", "/workspace"])
    @test root == "/workspace"
    @test options.jobs == 3 && options.threads == 2
    @test options.gpu_devices == ["0", "2"]
    @test options.excludes == ["generated/**"]
    @test !options.instantiate && !options.include_untracked
    for arguments in (String[], ["a", "b"], ["--unknown", "a"], ["--jobs"],
                      ["--jobs=2", "--jobs=3", "a"], ["--timeout=NaN", "a"])
        @test_throws ArgumentError JETSweep._parse_cli(arguments)
    end
end

@testset "Plan-only CLI path uses a fresh recursive inventory" begin
    mktempdir() do root
        write(joinpath(root, "utility.jl"), "square(x::Int) = x*x\n")
        output = joinpath(root, "reports")
        report = sweep(root; options=SweepOptions(output=output, plan_only=true), io=devnull)
        @test report.exit_code == 0
        @test length(report.inventory.files) == 1
        @test length(report.jobs) == 1
        @test isempty(report.results)
        @test isfile(joinpath(output, "plan.toml"))
        @test !isdir(joinpath(output, "jobs"))
        @test_throws ArgumentError sweep(root; options=SweepOptions(output=output, plan_only=true), io=devnull)
    end
end

@testset "Library import is inert and CLI help needs no target" begin
    code = "using JETSweep; println(\"library loaded\")"
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $code`
    @test strip(read(command, String)) == "library loaded"
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -m JETSweep --help`
    @test occursin("Usage: jetsweep", read(command, String))
end
