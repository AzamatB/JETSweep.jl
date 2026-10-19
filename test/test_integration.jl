using Test, JETSweep, TOML

const INTEGRATION_FIXTURE = joinpath(@__DIR__, "fixtures", "workspace")

function integration_copy(directory)
    root = joinpath(directory, "workspace")
    cp(INTEGRATION_FIXTURE, root)
    return root
end

integration_sweep(root, output; kwargs...) =
    sweep(root; options=SweepOptions(; jobs=8, threads=2, gpus=["none"], timeout=900.0, output, kwargs...),
          io=devnull)

integration_status(result, entry) = only(r.status for (u, r) in zip(result.units, result.results) if u.entry == entry)

@testset "sweep of a workspace with packages, extensions, tests and scripts" begin
    mktempdir() do directory
        root = integration_copy(directory)
        sources = Dict(path => read(path) for path in readdir(root; join=true) if isfile(path))
        result = integration_sweep(root, joinpath(directory, "report"))
        file(relative) = realpath(joinpath(root, relative))
        @test Set((u.kind, relpath(u.entry, root)) for u in result.units) == Set([
            (:package, "Witness/src/Witness.jl"), (:extension, "Witness/ext/WitnessTestExt.jl"),
            (:orphan, "Witness/src/disconnected.jl"), (:orphan, "Witness/src/inactive.jl"),
            (:test, "Witness/test/runtests.jl"), (:test, "Witness/test/test_dynamic.jl"),
            (:test, "Witness/test/test_independent.jl"), (:script, "scripts/main.jl"),
            (:script, "scripts/clean.jl"), (:script, "tools/report.jl")])
        @test all(r -> r.status in (:clean, :findings), result.results)
        @test integration_status(result, file("Witness/test/runtests.jl")) === :clean
        @test integration_status(result, file("scripts/clean.jl")) === :clean
        found = Set((relpath(f.file, root), f.line, f.code) for f in JETSweep.unique_findings(result.results))
        @test found == Set([
            ("Witness/src/Witness.jl", 6, "inference/method-error"),
            ("Witness/src/nested.jl", 1, "inference/method-error"),
            ("Witness/src/nested.jl", 4, "toplevel/abstract-field"),
            ("Witness/src/inactive.jl", 1, "inference/method-error"),
            ("Witness/src/disconnected.jl", 1, "inference/method-error"),
            ("Witness/ext/WitnessTestExt.jl", 6, "inference/method-error"),
            ("Witness/ext/helper.jl", 1, "inference/method-error"),
            ("Witness/test/test_dynamic.jl", 1, "inference/method-error"),
            ("scripts/main.jl", 3, "inference/method-error"),
            ("tools/report.jl", 3, "inference/method-error")])
        package = only(r for (u, r) in zip(result.units, result.results) if u.kind === :package)
        @test any(note -> occursin("inactive.jl", note), package.notes)
        @test result.exit_code == 1
        @test isempty(result.changed)
        @test all(path -> read(path) == sources[path], keys(sources))
        report = TOML.parsefile(joinpath(result.output, "report.toml"))
        @test report["exit_code"] == 1
        @test length(report["findings"]) == length(found)
        @test isempty(report["unanalyzed"])
        @test occursin("Witness/src/nested.jl:4:5: hint [toplevel/abstract-field]",
                       read(joinpath(result.output, "summary.txt"), String))
        @test isfile(joinpath(result.output, "plan.toml")) && isfile(joinpath(result.output, "inventory.toml"))
        # The tool's own threshold: every finding is a warning or hint here.
        @test JETSweep.exit_code(result.inventory, result.results, String[], :error) == 0
        @test JETSweep.exit_code(result.inventory, result.results, String[], :none) == 0
    end
end

@testset "incomplete analyses are explicit" begin
    mktempdir() do root
        write(joinpath(root, "missing_package.jl"), "using NotAPackageAnywhere\nf(x::Int) = x\n")
        write(joinpath(root, "unresolved.jl"), "const PATHS = readdir(pwd())\nstruct S\n    x::typeof(PATHS)\nend\n")
        mkpath(joinpath(root, "Broken", "src"))
        mkpath(joinpath(root, "Broken", "ext"))
        write(joinpath(root, "Broken", "Project.toml"), """
            name = "Broken"
            uuid = "bccf44ca-89c7-4396-ace9-39b586db3eee"
            version = "0.1.0"
            [weakdeps]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [extensions]
            BrokenTestExt = "Test"
            """)
        write(joinpath(root, "Broken", "src", "Broken.jl"), "module Broken\nvalue() = 1\nend\n")
        write(joinpath(root, "Broken", "ext", "BrokenTestExt.jl"), "module BrokenTestExt\nerror(\"broken extension\")\nend\n")
        output = joinpath(root, ".jetsweep", "report")
        result = integration_sweep(root, output; fail_on=:none)
        status(name) = integration_status(result, realpath(joinpath(root, name)))
        @test status("missing_package.jl") === :incomplete
        @test status("unresolved.jl") === :incomplete
        @test status("Broken/ext/BrokenTestExt.jl") === :failed
        @test status("Broken/src/Broken.jl") === :clean
        reasons = only(r.reasons for (u, r) in zip(result.units, result.results) if endswith(u.entry, "missing_package.jl"))
        @test any(reason -> occursin("toplevel/error", reason) && occursin("NotAPackageAnywhere", reason), reasons)
        @test result.exit_code == 2
        @test !isempty(TOML.parsefile(joinpath(output, "report.toml"))["unanalyzed"])
    end
end

@testset "plan only" begin
    mktempdir() do directory
        root = integration_copy(directory)
        result = sweep(root; options=SweepOptions(plan_only=true, output=joinpath(directory, "plan")), io=devnull)
        @test result.exit_code == 0
        @test isempty(result.results)
        # Package sources loading leaves out become orphan units only during a sweep.
        @test length(TOML.parsefile(joinpath(directory, "plan", "plan.toml"))["units"]) == length(result.units) == 8
        @test !isdir(joinpath(directory, "plan", "environments"))
    end
end
