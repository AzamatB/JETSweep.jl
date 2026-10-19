using Test, JETSweep, TOML

const INTEGRATION_FIXTURE = joinpath(@__DIR__, "fixtures", "workspace")

function integration_copy(directory)
    root = joinpath(directory, "workspace")
    cp(INTEGRATION_FIXTURE, root)
    return root
end

integration_sweep(root, output; io=devnull, kwargs...) =
    sweep(root; options=SweepOptions(; jobs=8, threads=2, gpus=["none"], timeout=900.0, output, kwargs...), io)

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
            (:orphan, "Witness/ext/dormant.jl"),
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
            # Analyzed in the extension's module, where `extension_failure` is defined.
            ("Witness/ext/dormant.jl", 1, "inference/method-error"),
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
        # JET analyzes nothing after a parse error.
        write(joinpath(root, "unparsable.jl"), "f(x) = x + 1\ny = )\nundefined_thing()\n")
        # Turning a stop's diagnostic off does not hide the stop.
        mkpath(joinpath(root, "silenced"))
        write(joinpath(root, "silenced", "stop.jl"),
              "name = rand() > 2 ? \"a\" : \"b\"\ninclude(joinpath(@__DIR__, name * \".jl\"))\nh() = 2\n")
        write(joinpath(root, "silenced", ".JETLSConfig.toml"), """
            [[diagnostic.patterns]]
            pattern = "toplevel/.*"
            match_by = "code"
            match_type = "regex"
            severity = "off"
            """)
        # Arguments are not evaluated where analysis does not need them; a selection that
        # JETLS evaluates to define the closure in its branch is.
        write(joinpath(root, "arguments.jl"), "outdir = ARGS[1]\noutput(name) = joinpath(outdir, name)\n")
        write(joinpath(root, "selection.jl"), """
            const ASKED = isempty(ARGS) ? split(get(ENV, "NOTHING_ASKED_FOR", ""), ","; keepempty=false) : ARGS
            const RUN = isempty(ASKED) ? ["a"] : filter(name -> name in ASKED, ["a"])
            selected() = RUN
            """)
        # A script loads a package of its workspace that no project of it declares.
        mkpath(joinpath(root, "Sibling", "src"))
        write(joinpath(root, "Sibling", "Project.toml"),
              "name = \"Sibling\"\nuuid = \"6f4d0fd2-62a3-4c43-9d6e-0c3fdd2a6f3b\"\nversion = \"0.1.0\"\n")
        write(joinpath(root, "Sibling", "src", "Sibling.jl"), "module Sibling\nsibling_value() = 1\nend\n")
        write(joinpath(root, "uses_sibling.jl"), "using Sibling\nuse() = Sibling.sibling_value() + \"one\"\n")
        # A closure in a branch of a top-level expression does not stop the analysis, and the
        # value its condition reads is not evaluated.
        write(joinpath(root, "locked.jl"), """
            acquire() = (touch(joinpath(@__DIR__, "acquired.marker")); nothing)
            const LOCK = acquire()
            LOCK === nothing || atexit(() -> close(LOCK))
            after() = 1 + "one"
            """)
        # Code loaded with `include_string` is loaded.
        write(joinpath(root, "bootstrap.jl"), """
            const CODE = read(joinpath(@__DIR__, "bootstrapped.txt"), String)
            include_string(@__MODULE__, CODE, "bootstrapped.jl")
            using .Bootstrapped
            use() = Bootstrapped.value() + "one"
            """)
        write(joinpath(root, "bootstrapped.txt"), "module Bootstrapped\nvalue() = 1\nend\n")
        # A generator in a branch of a `@test` expression does not make JETLS run the test.
        write(joinpath(root, "outlined.jl"), """
            using Test
            const MARKER = joinpath(@__DIR__, "ran.marker")
            setup() = (touch(MARKER); (ok=true, items=[(b=1,)]))
            @testset "outlined" begin
                r = setup()
                @test r.ok && [a.b for a in r.items] == [1]
            end
            """)
        output = joinpath(root, ".jetsweep", "report")
        io = IOBuffer()
        result = integration_sweep(root, output; io, fail_on=:none)
        status(name) = integration_status(result, realpath(joinpath(root, name)))
        reasons(name) = only(r.reasons for (u, r) in zip(result.units, result.results) if endswith(u.entry, name))
        @test status("missing_package.jl") === :incomplete
        @test status("unresolved.jl") === :incomplete
        @test status("Broken/ext/BrokenTestExt.jl") === :failed
        @test status("Broken/src/Broken.jl") === :clean
        @test any(reason -> occursin("toplevel/error", reason) && occursin("NotAPackageAnywhere", reason),
                  reasons("missing_package.jl"))
        @test status("unparsable.jl") === :incomplete
        @test any(reason -> occursin("syntax/parse-error", reason), reasons("unparsable.jl"))
        @test status("silenced/stop.jl") === :incomplete
        @test any(reason -> occursin("silenced/stop.jl:2 [toplevel/", reason), reasons("silenced/stop.jl"))
        @test status("arguments.jl") in (:clean, :findings)
        @test status("selection.jl") === :clean
        @test status("outlined.jl") === :clean && !isfile(joinpath(root, "ran.marker"))
        @test status("locked.jl") === :findings && !isfile(joinpath(root, "acquired.marker"))
        @test status("bootstrap.jl") === :findings
        @test status("uses_sibling.jl") === :findings
        sibling = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, "uses_sibling.jl"))
        @test any(note -> occursin("It adds packages imported without being declared: Sibling.", note), sibling.notes)
        @test result.exit_code == 2
        @test !isempty(TOML.parsefile(joinpath(output, "report.toml"))["unanalyzed"])
        # The terminal summary groups incomplete analyses by cause, with paths relative to the root.
        summary = String(take!(io))
        @test occursin(r"\n +1  incomplete  \[syntax/parse-error\]: [^\n]+\n +unparsable\.jl\n", summary)
        @test occursin("silenced/stop.jl", summary) && !occursin(realpath(root) * "/silenced", summary)
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
