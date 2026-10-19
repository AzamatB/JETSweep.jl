using Test, JETSweep
isdefined(@__MODULE__, :discovery_tree) || include("test_discovery_fixtures.jl")

@testset "Complete source planning and inferred helper context" begin
    mktempdir() do root
        paths = discovery_tree(root)
        inventory = discover(root; output=joinpath(root, "audit output"))
        jobs = plan(inventory)
        package = only(filter(job -> job.kind == :package && job.owner == paths.first, jobs))
        @test !(joinpath(paths.first, "src/disconnected.jl") in package.expected_files)
        disconnected = only(filter(job -> job.entry == joinpath(paths.first, "src/disconnected.jl"), jobs))
        @test disconnected.kind == :source
        @test disconnected.owner == paths.first
        @test disconnected.expected_files == [disconnected.entry]
        @test isempty(disconnected.blocking_issues)
        @test !(joinpath(paths.nested, "src/Nested.jl") in package.expected_files)
        @test length(filter(job -> job.kind == :package, jobs)) == 4
        @test length(unique(job.id for job in jobs)) == length(jobs)
        extension = only(filter(job -> job.kind == :extension, jobs))
        @test extension.owner == paths.first
        @test extension.triggers == Dict("Dates" => "ade2ca70-3891-5945-98fb-dc099432e06a")
        @test joinpath(paths.first, "ext/RepeatedDatesExt/helper.jl") in extension.expected_files
        helper = only(filter(job -> job.entry == joinpath(paths.first, "test/groups/helper.jl"), jobs))
        @test helper.kind == :test
        @test helper.project == joinpath(paths.first, "test")
        @test helper.context.test_entry == joinpath(paths.first, "test/runtests.jl")
        @test helper.context.containing_files == [joinpath(paths.first, "test/groups/basic.jl")]
        @test isempty(helper.issues)
        @test all(source -> any(job -> source.path in job.expected_files, jobs), inventory.files)
        @test [job.id for job in jobs] == [job.id for job in plan(inventory)]
        discovery_file(paths.first, "test/runtests.jl", "using Test\ninclude(\"groups/basic.jl\")\nfor path in ARGS\n include(path)\nend\n")
        updated = plan(discover(root; output=joinpath(root, "audit output")))
        leaf = only(filter(job -> job.entry == joinpath(paths.first, "test/groups/helper.jl"), updated))
        driver = only(filter(job -> job.entry == joinpath(paths.first, "test/runtests.jl"), updated))
        @test isempty(leaf.issues)
        @test any(issue -> occursin("dynamic include", issue), driver.issues)
    end
end

@testset "Alternate package entries retain their included source context" begin
    mktempdir() do root
        package = discovery_project(root, "alternate"; name="AlternateRoot",
            uuid="18825ed6-68b4-4278-8fd7-c3d5d3abe818", entry="lib/Main.jl")
        mv(joinpath(package, "Project.toml"), joinpath(package, "JuliaProject.toml"))
        entry = discovery_file(package, "lib/Main.jl", """
            module AlternateRoot
            struct InternalValue
                value::Int
            end
            include("helper.jl")
            include("nested/src/Nested.jl")
            end
            """)
        helper = discovery_file(package, "lib/helper.jl", "read_value(value::InternalValue) = value.value\n")
        orphan = discovery_file(package, "src/orphan.jl", "orphan(x::Int) = x + 1\n")
        nested = discovery_project(package, "lib/nested"; name="Nested",
            uuid="0190370f-ac35-4269-bcd4-2db89560c177")
        inventory = discover(root)
        jobs = plan(inventory)
        package_job = only(filter(job -> job.kind === :package && job.owner == package, jobs))
        helper_record = only(filter(file -> file.path == helper, inventory.files))
        @test helper_record.kind === :script
        @test helper_record.owner == package
        @test package_job.entry == entry
        @test package_job.expected_files == sort([entry, helper])
        @test count(job -> helper in job.expected_files, jobs) == 1
        @test all(job -> job.entry != helper, jobs)
        @test !(joinpath(nested, "src/Nested.jl") in package_job.expected_files)
        @test only(filter(job -> job.entry == orphan, jobs)).kind === :source
        @test all(file -> any(job -> file.path in job.expected_files, jobs), inventory.files)
    end
end

@testset "Syntax discovery records dynamic and unavailable contexts" begin
    mktempdir() do root
        discovery_file(root, "entry.jl", "const directory = joinpath(@__DIR__, \"helpers\")\ninclude(joinpath(directory, \"target.jl\"))\n")
        discovery_file(root, "helpers/target.jl", "target(x) = x\n")
        discovery_file(root, "dynamic.jl", "include(ARGS[1])\n")
        discovery_file(root, "missing.jl", "include(\"absent.jl\")\n")
        discovery_file(root, "malformed.jl", "function bad(\n")
        discovery_file(root, "macros.jl", "@custom function user_macro(x)\n x\nend\n")
        discovery_file(root, "conditional.jl", "if flag\n filename = \"a.jl\"\nelse\n filename = \"b.jl\"\nend\ninclude(filename)\n")
        jobs = plan(discover(root))
        byname = Dict(basename(job.entry) => job for job in jobs)
        @test byname["target.jl"].context.containing_files == [joinpath(root, "entry.jl")]
        @test byname["entry.jl"].project == ""
        @test isempty(byname["macros.jl"].issues)
        @test any(issue -> occursin("dynamic include", issue), byname["dynamic.jl"].issues)
        @test isempty(byname["dynamic.jl"].blocking_issues)
        @test any(issue -> occursin("source does not exist", issue), byname["missing.jl"].issues)
        @test isempty(byname["missing.jl"].blocking_issues)
        @test any(issue -> occursin("source parse failed", issue), byname["malformed.jl"].issues)
        @test !isempty(byname["malformed.jl"].blocking_issues)
        @test any(issue -> occursin("dynamic include", issue), byname["conditional.jl"].issues)
        discovery_file(root, "another.jl", "include(\"helpers/target.jl\")\n")
        target = only(filter(job -> basename(job.entry) == "target.jl", plan(discover(root))))
        @test any(issue -> occursin("multiple containing files", issue), target.issues)
        @test isempty(target.blocking_issues)
        discovery_file(root, "setup.jl", "const context_value = 1\n")
        discovery_file(root, ".JETSweep.toml", "[[jobs]]\nmatch = \"helpers/target.jl\"\nsetup = [\"setup.jl\"]\n")
        target = only(filter(job -> basename(job.entry) == "target.jl", plan(discover(root))))
        @test isempty(target.issues)
    end
end

@testset "Static missing include targets remain advisory" begin
    mktempdir() do root
        package = discovery_project(root, "."; name="OptionalInclude",
            uuid="0dc3a9ce-c6fe-4d1e-868f-147c5c2cb5d0")
        entry = joinpath(package, "src/OptionalInclude.jl")
        for conditional in ("false", "isfile(joinpath(@__DIR__, \"optional.jl\"))", "optional_feature_enabled()")
            write(entry, "module OptionalInclude\nif $conditional\n include(\"optional.jl\")\nend\nend\n")
            job = only(plan(discover(root)))
            @test any(issue -> occursin("included source does not exist", issue), job.issues)
            @test isempty(job.blocking_issues)
        end
        # An unconditional include is also execution-dependent at this stage;
        # the real loader/JETLS must report its failure, rather than a heuristic.
        write(entry, "module OptionalInclude\ninclude(\"optional.jl\")\nend\n")
        @test isempty(only(plan(discover(root))).blocking_issues)
        rm(entry)
        @test any(issue -> occursin("expected source does not exist", issue), only(plan(discover(root))).blocking_issues)
    end
end

@testset "Static pkgdir paths follow declared identities instead of sibling names" begin
    mktempdir() do directory
        root = joinpath(directory, "workspace")
        dependency_uuid = "9ca1778b-f46c-4c8c-8a17-9122cc7a78bf"
        owner_uuid = "d934767a-63cc-4f1f-a271-8b7c0637859f"
        owner = discovery_project(root, "Owner"; name="Owner", uuid=owner_uuid,
            extra=Dict("deps" => Dict("Dep" => dependency_uuid)))
        discovery_project(root, "Owner duplicate"; name="Owner", uuid=owner_uuid)
        decoy = discovery_project(root, "Dep"; name="Dep", uuid=dependency_uuid)
        actual = discovery_project(directory, "actual_dependency"; name="Dep", uuid=dependency_uuid)
        replacement = discovery_project(directory, "explicit_dependency"; name="Dep", uuid=dependency_uuid)
        discovery_file(actual, "bootstrap.jl", "const SOURCE_ORIGIN = :manifest\n")
        discovery_file(replacement, "bootstrap.jl", "const SOURCE_ORIGIN = :explicit\n")
        entry = discovery_file(owner, "src/Owner.jl", "module Owner\nusing Dep\ninclude(joinpath(pkgdir(Dep), \"bootstrap.jl\"))\nend\n")
        inventory = discover(root)
        source = only(filter(file -> file.path == entry, inventory.files))
        unresolved = JETSweep._source_package_paths(source, inventory)
        @test unresolved["Owner"] == owner
        @test !haskey(unresolved, "Dep")
        job = only(filter(job -> job.entry == entry, plan(inventory)))
        @test any(issue -> occursin("dynamic include", issue), job.issues)
        @test isempty(job.blocking_issues)

        function write_manifest(name, path)
            open(joinpath(owner, name), "w") do io
                TOML.print(io, Dict("manifest_format" => "2.0", "julia_version" => string(VERSION),
                    "deps" => Dict("Dep" => [Dict("uuid" => dependency_uuid, "version" => "0.1.0", "path" => path)])))
            end
        end
        write_manifest("Manifest.toml", decoy)
        write_manifest("Manifest-v$(VERSION.major).$(VERSION.minor).toml", actual)
        selected = JETSweep._source_package_paths(source, inventory)
        @test selected["Dep"] == actual
        job = only(filter(job -> job.entry == entry, plan(inventory)))
        @test !any(issue -> occursin(joinpath(decoy, "bootstrap.jl"), issue), job.issues)
        @test isempty(job.blocking_issues)

        project_file = joinpath(owner, "Project.toml")
        data = TOML.parsefile(project_file)
        data["sources"] = Dict("Dep" => Dict("path" => relpath(replacement, owner)))
        open(io -> TOML.print(io, data), project_file, "w")
        @test JETSweep._source_package_paths(source, inventory)["Dep"] == replacement
        # A URL declaration supersedes stale development paths, but cannot be
        # resolved statically by choosing a conveniently named sibling.
        data["sources"] = Dict("Dep" => Dict("url" => "https://example.invalid/Dep.jl"))
        open(io -> TOML.print(io, data), project_file, "w")
        @test !haskey(JETSweep._source_package_paths(source, inventory), "Dep")
        data["sources"] = Dict("Dep" => Dict("path" => relpath(replacement, owner)))
        open(io -> TOML.print(io, data), project_file, "w")
        replacement_data = TOML.parsefile(joinpath(replacement, "Project.toml"))
        replacement_data["uuid"] = "831b5e3b-276a-4cf6-80ad-d2d348d77e1f"
        open(io -> TOML.print(io, replacement_data), joinpath(replacement, "Project.toml"), "w")
        @test !haskey(JETSweep._source_package_paths(source, inventory), "Dep")
    end
end

@testset "Declarative per-job context overrides" begin
    mktempdir() do root
        discovery_file(root, "script.jl")
        discovery_file(root, "setup.jl", "const supplied_value = 1\n")
        discovery_project(root, "environment")
        discovery_file(root, "jetls.toml", "\n")
        discovery_file(root, ".JETSweep.toml", """
            [[jobs]]
            match = "script.jl"
            project = "environment"
            setup = ["setup.jl"]
            args = ["hello world", "--flag"]
            jetls_config = "jetls.toml"
            [jobs.env]
            EXAMPLE_SELECTOR = "tests"
            """)
        job = only(filter(job -> basename(job.entry) == "script.jl", plan(discover(root))))
        @test job.project == joinpath(root, "environment")
        @test job.context.project == job.project
        @test job.context.setup == [joinpath(root, "setup.jl")]
        @test job.context.arguments == ["hello world", "--flag"]
        @test job.context.variables == Dict("EXAMPLE_SELECTOR" => "tests")
        @test job.context.configuration == joinpath(root, "jetls.toml")
        discovery_file(root, ".JETSweep.toml", "[[jobs]]\nmatch = \"absent.jl\"\n")
        @test_throws ArgumentError plan(discover(root))
        discovery_file(root, ".JETSweep.toml", "[[jobs]]\nmatch = \"*.jl\"\nunknown = true\n")
        @test_throws ArgumentError plan(discover(root))
    end
end
