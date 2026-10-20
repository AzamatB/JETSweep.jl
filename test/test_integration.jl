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
        findings = JETSweep.unique_findings(result.results)
        messages = Dict((relpath(f.file, root), f.line, f.code) => f.message for f in findings)
        found = Set(keys(messages))
        @test found == Set([
            ("Witness/src/Witness.jl", 6, "inference/method-error"),
            ("Witness/src/nested.jl", 1, "inference/method-error"),
            ("Witness/src/nested.jl", 4, "toplevel/abstract-field"),
            ("Witness/src/inactive.jl", 1, "inference/method-error"),
            ("Witness/src/disconnected.jl", 1, "inference/method-error"),
            ("Witness/src/disconnected.jl", 2, "inference/undef-global-var"),
            ("Witness/src/disconnected.jl", 2, "lowering/undef-global-var"),
            ("Witness/ext/WitnessTestExt.jl", 6, "inference/method-error"),
            ("Witness/ext/helper.jl", 1, "inference/method-error"),
            # Analyzed in the extension's module, where `extension_failure` is defined.
            ("Witness/ext/dormant.jl", 1, "inference/method-error"),
            ("Witness/test/test_dynamic.jl", 1, "inference/method-error"),
            ("scripts/main.jl", 3, "inference/method-error"),
            ("scripts/main.jl", 9, "inference/field-error"),
            ("scripts/main.jl", 11, "inference/undef-global-var"),
            ("scripts/main.jl", 11, "lowering/undef-global-var"),
            ("scripts/main.jl", 13, "inference/method-error"),
            ("tools/report.jl", 3, "inference/method-error")])
        # Messages name what scripts and orphans define as JETLS names what `Main` defines,
        # without the module they are analyzed in, and without mangling `MyMain`.
        @test messages["scripts/main.jl", 9, "inference/field-error"] ==
              "FieldError: type `Point` has no field `y`, available fields: `x`"
        @test messages["scripts/main.jl", 11, "inference/undef-global-var"] ==
              messages["scripts/main.jl", 11, "lowering/undef-global-var"] == "`MyMain.not_defined_in_mymain` is not defined"
        @test messages["Witness/src/disconnected.jl", 2, "inference/undef-global-var"] ==
              "`not_defined_anywhere` is not defined"
        # Columns count UTF-16 code units, as LSP positions do, and a whole-line diagnostic
        # ends where its line does.
        wide = only(f for f in findings if relpath(f.file, root) == "scripts/main.jl" && f.line == 13)
        @test (wide.column, wide.end_line, wide.end_column) == (1, 13, 28)
        @test all(f -> f.end_column <= length(transcode(UInt16, readlines(f.file)[f.end_line])) + 1, findings)
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
        # Where a message locates a method, it names the module as JETLS does.
        write(joinpath(root, "kwdef.jl"), "Base.@kwdef struct Opts{T}\n    a::T = 1\nend\nmake() = Opts(1, 2)\n")
        # A tier of tests an environment variable enables is analyzed without it.
        write(joinpath(root, "gated.jl"), """
            using Test
            if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                @testset "tier" begin
                    foreach(x -> println(x), 1:2)
                    sin("tier")
                end
            end
            """)
        # A line ending in "\r\n" ends before its '\r'.
        write(joinpath(root, "crlf.jl"), "crlf_failure() = sin(\"abc\")\r\ncrlf_failure()\r\n")
        write(joinpath(root, "unresolved.jl"), "const PATHS = rand(Bool) ? [\"a\"] : String[]\nstruct S\n    x::typeof(PATHS)\nend\n")
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
        # Nor does one in a branch of a top-level loop.
        write(joinpath(root, "loop.jl"), """
            const LISTED = readdir(ARGS[1])
            for item in LISTED
                if isdir(item)
                    foreach(x -> println(x), item)
                end
            end
            after() = 1 + "one"
            """)
        # What outlined code does wrong is reported where it does it.
        write(joinpath(root, "inside.jl"), """
            const LOCK = rand(Bool) ? nothing : 1
            LOCK === nothing || (sin("one"); atexit(() -> close(LOCK)))
            for item in readdir(@__DIR__)
                if isdir(item)
                    foreach(x -> println(x), item)
                end
                cos("two")
            end
            using Test
            @test isempty(ARGS) || (tan("three") > 0 && all(a -> a > 0, [1]))
            for n in 1:2
                @test n
                n > 1 && foreach(x -> println(x), 1:n)
            end
            for item in readdir(sin("four"))
                # The header is reported where it stands.
                isdir(item) && foreach(x -> println(x), item)
            end
            """)
        # A script runs as the program, so a check for that holds as it would.
        write(joinpath(root, "main_check.jl"), """
            const MAIN = abspath(PROGRAM_FILE) == abspath(@__FILE__)
            if MAIN
                report() = foreach(x -> println(x), 1:2)
            end
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
        # A stop in the prelude of a test file a driver includes at run time is reported where
        # the driver stops.
        mkpath(joinpath(root, "Preluded", "src"))
        mkpath(joinpath(root, "Preluded", "test"))
        write(joinpath(root, "Preluded", "Project.toml"), """
            name = "Preluded"
            uuid = "0c5a3f2e-7d41-4b8a-9e6f-3a2b1c0d9e8f"
            version = "0.1.0"
            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [targets]
            test = ["Test"]
            """)
        write(joinpath(root, "Preluded", "src", "Preluded.jl"), "module Preluded\nend\n")
        write(joinpath(root, "Preluded", "test", "runtests.jl"), """
            using Test

            const TESTS = ["wrapped.jl"]

            struct Wrapper{T<:NotDefinedAnywhere}
                x::T
            end

            for file in (isempty(ARGS) ? TESTS : ARGS)
                include(file)
            end
            """)
        write(joinpath(root, "Preluded", "test", "wrapped.jl"), "@test Wrapper(1).x == 1\n")
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
        # Tiers whose other branch logs, or whose tests stand in a `let` block, are analyzed
        # whatever their conditions.
        write(joinpath(root, "tiers.jl"), """
            using Test
            if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                @testset "logged" begin
                    foreach(x -> println(x), 1:2)
                    sin("logged")
                end
            else
                @info "skipped"
            end
            if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                println("setup")
                let n = 2
                    @testset "scoped" begin
                        foreach(x -> println(x + n), 1:n)
                        cos("scoped")
                    end
                end
            end
            """)
        # Nor do closures under control flow in a test set make JETLS run its statements or
        # leave them undefined.
        write(joinpath(root, "testsets.jl"), """
            using Test
            const RAN = joinpath(@__DIR__, "testsets.marker")
            items() = (touch(RAN); [1, 2])
            @testset "a branch" begin
                if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                    foreach(x -> println(x), 1:2)
                    sin("branch")
                end
            end
            @testset "closures of the test set's values in a loop" begin
                xs = items()
                for (f, n) in ((() -> xs[1] + 1, 1), (() -> xs[2] + 1, 2))
                    try
                        @test f() > n
                    finally
                        nothing
                    end
                end
                tan("loop")
            end
            """)
        # A conditional that binds names, as a driver's selection of its files does, has the
        # test sets in it that define closures under control flow analyzed by themselves,
        # whichever branch runs, and finds what a branch defines defined after it.
        write(joinpath(root, "driver.jl"), """
            using Test
            if !isempty(ARGS)
                include(ARGS[1])
            else
                helper(x) = x + 1
                @testset "all" begin
                    @test helper(1) == 2
                    if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                        foreach(x -> println(x), 1:2)
                        sin("tier")
                    end
                end
            end
            if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                tiered() = 1
                @testset "untaken" begin
                    if isempty(ARGS)
                        foreach(x -> println(x), 1:2)
                        cos("untaken")
                    end
                end
            end
            """)
        # The constants of a statement JETLS leaves unevaluated are all bound, also after a
        # closure in a loop, with what JETLS knows of them; and code after it is analyzed.
        write(joinpath(root, "constants.jl"), """
            parsed(args) = (isempty(args) ? "mode" : args[1], "out.json")
            const MODE, OUT = parsed(ARGS)
            out() = sin(OUT)
            const CONTRACT_ONLY = get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
            if !CONTRACT_ONLY
                const ROOT = joinpath(@__DIR__, MODE)
                const LANE = isempty(MODE) ? "default" : MODE
                const REPORTS = string(ROOT, "/", LANE)
            end
            reports() = REPORTS
            report_count() = reports() + 1
            untyped() = Base.inferencebarrier(1)::Any
            const VALUE = untyped()
            value() = VALUE
            use_value() = sin(value())
            let
                for x in 1:2
                    f = y -> y + x
                end
                tan("after the loop")
            end
            """)
        # What only top-level code may hold keeps the local scope holding it at top level,
        # however JETLS would analyze the closures in it there; code that evaluates code too.
        write(joinpath(root, "toplevel.jl"), """
            using Test
            struct Shown end
            let
                struct Local
                    x::Int
                end
                isempty(ARGS) || foreach(x -> println(x), ARGS)
            end
            use_local() = Local(1).x + "one"
            @testset "methods of functions that are not local" begin
                Base.show(io::IO, ::Shown) = print(io, "S")
                global const LIMIT = 3
                for x in [Shown()]
                    x isa Shown && @test all(c -> c != 'x' && LIMIT > 0, sprint(show, x))
                end
                sin("shown")
            end
            try
                global handler(x) = x + 1
                for i in 1:2
                    g = () -> i
                end
            catch
            end
            handler("one")
            for name in (:alpha,)
                name === :alpha && foreach(x -> x, 1:2)
                Base.@eval generated() = 1
            end
            generated() + "one"
            """)
        # A test that always fails in a statement moved out of a conditional is reported, as at
        # top level.
        write(joinpath(root, "failing.jl"), """
            using Test
            if isempty(ARGS)
                helper() = 1
                for n in 1:2
                    @test n
                    n > 1 && foreach(x -> println(x), 1:n)
                end
            end
            """)
        # A condition on values such as `@__FILE__` binds nothing either.
        write(joinpath(root, "program.jl"), """
            if basename(@__FILE__) == "never.jl"
                let n = 2
                    foreach(x -> println(x + n), 1:n)
                    sin("program")
                end
            end
            """)
        # Nor does a closure in a branch of a top-level `try` block make JETLS run the block.
        write(joinpath(root, "tried.jl"), """
            const TRIED = joinpath(@__DIR__, "tried.marker")
            items() = (touch(TRIED); [1, 2])
            try
                xs = items()
                isempty(xs) || foreach(x -> println(x), xs)
                cos("tried")
            catch
            end
            """)
        # A statement whose local functions' signatures read what its conditional defines,
        # or may include, stays in it, since a moved statement is defined before it.
        write(joinpath(root, "typed.jl"), """
            using Test
            if isempty(ARGS)
                struct Point
                    x::Int
                end
                @testset "a typed helper of the branch's type" begin
                    norm1(q::Point) = abs(q.x)
                    for p in [Point(1)]
                        p.x > 0 && foreach(y -> println(y), 1:2)
                        @test norm1(p) == 1
                    end
                    sin("typed")
                end
            end
            if isempty(ARGS)
                include(joinpath(@__DIR__, "typed_types.txt"))
                @testset "a typed helper of an included type" begin
                    unbox(b::IncludedBox) = b.v
                    for b in [IncludedBox(1)]
                        b.v > 0 && foreach(y -> println(unbox(y)), [b])
                    end
                    cos("included")
                end
            end
            if !isempty(ARGS)
                selected() = 1
                @testset "a typed helper of Base types" begin
                    twice(x::Float64) = 2x
                    if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                        foreach(y -> println(twice(y)), [1.0])
                    end
                    tan("based")
                end
            end
            """)
        write(joinpath(root, "typed_types.txt"), "struct IncludedBox\n    v::Int\nend\n")
        # The tests of a tier not taken find what the tier defines before them, closures in
        # them too, and its code after a definition is analyzed.
        write(joinpath(root, "untaken.jl"), """
            using Test
            if get(ENV, "JETSWEEP_TIER_NEVER_SET", "") == "1"
                struct GPUThing
                    n::Int
                end
                gpu_helper(t) = t.n + 1
                const GPU_N = 4
                thing = GPUThing(GPU_N)
                sin("after the definitions")
                @testset "tests of what the tier defines" begin
                    for n in 1:GPU_N
                        @test all(y -> gpu_helper(GPUThing(y)) > 0, 1:n)
                        n > 1 && foreach(x -> println(gpu_helper(thing)), 1:n)
                    end
                    cos("untaken")
                end
            end
            """)
        # Outlined code finds defined what top-level code defined before it, a test set's own
        # code or its branch's; code that runs later may find a global undefined.
        write(joinpath(root, "defined.jl"), """
            using Test
            compute() = [1, 2]
            if isempty(ARGS)
                const N = parse(Int, "3")
                data = compute()
                helper() = 1
                @testset "reads what the branch defined before" begin
                    for i in 1:N
                        i > 1 && foreach(y -> println(y), data)
                    end
                    sin("branch")
                end
            end
            @testset "reads what the test set assigned" begin
                global RESULT = compute()
                for i in 1:2
                    @test all(x -> x > 0, RESULT)
                end
                cos("test set")
            end
            total() = sum(RESULT)
            """)
        output = joinpath(root, ".jetsweep", "report")
        io = IOBuffer()
        result = integration_sweep(root, output; io, fail_on=:none)
        status(name) = integration_status(result, realpath(joinpath(root, name)))
        reasons(name) = only(r.reasons for (u, r) in zip(result.units, result.results) if endswith(u.entry, name))
        @test status("missing_package.jl") === :incomplete
        gated = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, "gated.jl"))
        @test any(f -> f.code == "inference/method-error" && f.line == 5, gated.findings)
        @test !any(f -> occursin("undef-global-var", f.code), gated.findings)
        kwdef = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, "kwdef.jl"))
        @test any(f -> occursin("@ Main ", f.message), kwdef.findings)
        @test !any(f -> occursin("JETSweepAnalysis", f.message), kwdef.findings)
        crlf = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, "crlf.jl"))
        @test !isempty(crlf.findings) && all(f -> f.end_column <= 28, crlf.findings)
        @test any(f -> f.line == 1 && f.end_line == 1 && f.end_column == 28, crlf.findings)
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
        unit(name) = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, name))
        errors(name) = sort!([f.line for f in unit(name).findings if f.code == "inference/method-error"])
        undefined(name) = [f for f in unit(name).findings if occursin("undef-global-var", f.code)]
        @test errors("tiers.jl") == [5, 15] && isempty(undefined("tiers.jl"))
        @test errors("testsets.jl") == [7, 19] && isempty(undefined("testsets.jl"))
        @test !isfile(joinpath(root, "testsets.marker"))
        @test errors("driver.jl") == [10, 19] && isempty(undefined("driver.jl"))
        @test errors("constants.jl") == [3, 11, 20]
        # Code that runs later may find the conditional's constants undefined, the statement
        # that assigns them not.
        @test [(f.line, f.severity) for f in undefined("constants.jl")] == [(10, 3)]
        @test !any(f -> occursin("AbstractBindingState", f.message), unit("constants.jl").findings)
        @test status("toplevel.jl") === :findings && errors("toplevel.jl") == [9, 16, 19, 30]
        @test !any(f -> occursin("LIMIT", f.message) || occursin("generated", f.message), unit("toplevel.jl").findings)
        @test any(f -> f.code == "inference/failing-test" && f.line == 5, unit("failing.jl").findings)
        @test errors("program.jl") == [4] && isempty(undefined("program.jl"))
        @test errors("tried.jl") == [6] && isempty(undefined("tried.jl")) && !isfile(joinpath(root, "tried.marker"))
        @test status("typed.jl") === :findings && errors("typed.jl") == [12, 22, 32] && isempty(undefined("typed.jl"))
        @test errors("untaken.jl") == [9, 15] && isempty(undefined("untaken.jl"))
        @test errors("defined.jl") == [11, 19] && [(f.line, f.severity) for f in undefined("defined.jl")] == [(21, 3)]
        @test status("locked.jl") === :findings && !isfile(joinpath(root, "acquired.marker"))
        @test status("bootstrap.jl") === :findings
        @test status("main_check.jl") === :findings
        @test status("loop.jl") === :findings
        inside = only(r for (u, r) in zip(result.units, result.results) if endswith(u.entry, "inside.jl"))
        @test issubset([2, 7, 10, 15], [f.line for f in inside.findings if f.code == "inference/method-error"])
        # A test that always fails is reported in outlined code as at top level.
        @test any(f -> f.code == "inference/failing-test" && f.line == 12, inside.findings)
        @test status("Preluded/test/wrapped.jl") === :incomplete
        @test reasons("Preluded/test/wrapped.jl") == reasons("Preluded/test/runtests.jl")
        @test any(reason -> occursin("Preluded/test/runtests.jl:5 [toplevel/error]", reason),
                  reasons("Preluded/test/wrapped.jl"))
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

@testset "environments are prepared again when what they were prepared from changes during the run" begin
    mktempdir() do directory
        root = mkpath(joinpath(directory, "workspace"))
        file(path, text) = (mkpath(dirname(joinpath(root, path))); write(joinpath(root, path), text))
        helper = "0b0d6c7e-5d5c-4b8e-9f1e-3f1b1ad2c0de"
        helper_project(deps) = "name = \"Helper\"\nuuid = \"$helper\"\nversion = \"0.1.0\"\n$deps"
        file("Helper/Project.toml", helper_project(""))
        file("Helper/src/Helper.jl", "module Helper\nvalue() = 1\nend\n")
        file("Dependent/Project.toml", """
            name = "Dependent"
            uuid = "7a4f2e61-3c1d-4f0b-8e2a-9d5c6b7a8e10"
            version = "0.1.0"

            [deps]
            Helper = "$helper"

            [sources]
            Helper = {path = "../Helper"}
            """)
        file("Dependent/src/Dependent.jl", "module Dependent\nusing Helper\nvalue() = Helper.value()\nend\n")
        # Loading Mutator, whose analysis is the longest and so runs first, after every environment is
        # prepared, makes Helper import Random, as an edit during the run would.
        file("Mutator/Project.toml", "name = \"Mutator\"\nuuid = \"c3e9a1b2-6f4d-4e8a-b0c7-1d2e3f4a5b6c\"\nversion = \"0.1.0\"\n")
        file("Mutator/src/Mutator.jl", """
            module Mutator
            $(repeat("# Padding that makes this the longest analysis.\n", 1000))
            function __init__()
                get(ENV, "MUTATE_HELPER", "") == "1" || return
                helper = joinpath(@__DIR__, "..", "..", "Helper")
                write(joinpath(helper, "Project.toml"), $(repr(helper_project("\n[deps]\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n"))))
                write(joinpath(helper, "src", "Helper.jl"), "module Helper\\nusing Random\\nvalue() = 2\\nend\\n")
            end
            end
            """)
        file(".JETSweep.toml", "[[context]]\nmatch = \"Mutator/src/Mutator.jl\"\nenv = { MUTATE_HELPER = \"1\" }\n")
        result = sweep(root; options=SweepOptions(jobs=1, threads=1, gpus=["none"], timeout=900.0,
                                                  output=joinpath(directory, "report")), io=devnull)
        outcome(name) = integration_status(result, realpath(joinpath(root, name, "src", "$name.jl")))
        notes(name) = only(r.notes for (u, r) in zip(result.units, result.results) if endswith(u.entry, "$name.jl"))
        @test occursin("using Random", read(joinpath(root, "Helper", "src", "Helper.jl"), String))
        # Without preparing them again, both fail to load: "Cannot load module Random into module Helper".
        again(name) = any(note -> startswith(note, "environment: It was prepared again, since ") &&
                                  endswith(note, "/Helper/Project.toml changed during the run."), notes(name))
        @test outcome("Dependent") === :clean && again("Dependent")
        @test outcome("Helper") === :clean && again("Helper")
        @test outcome("Mutator") === :clean && isempty(notes("Mutator"))
        @test realpath(joinpath(root, "Helper", "Project.toml")) in result.changed
        @test result.exit_code == 2
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
