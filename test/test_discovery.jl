using Test, JETSweep
isdefined(@__MODULE__, :discovery_tree) || include("test_discovery_fixtures.jl")

@testset "Recursive discovery uses paths and project identity" begin
    mktempdir() do root
        paths = discovery_tree(root)
        inventory = discover(root; output=joinpath(root, "audit output"))
        bypath = Dict(project.path => project for project in inventory.projects)
        files = Dict(source.path => source for source in inventory.files)
        @test length(inventory.projects) == 7
        @test bypath[paths.first].name == bypath[paths.second].name == "Repeated"
        @test bypath[paths.first].uuid != bypath[paths.second].uuid
        @test bypath[root].name == ""
        @test bypath[paths.alternate].entry == joinpath(paths.alternate, "lib/start.jl")
        @test files[joinpath(paths.alternate, "lib/start.jl")].kind == :package_source
        @test files[joinpath(paths.first, "test/groups/helper.jl")].project == joinpath(paths.first, "test")
        @test files[joinpath(paths.first, "test/groups/helper.jl")].owner == paths.first
        @test files[joinpath(paths.nested, "src/Nested.jl")].owner == paths.nested
        @test haskey(files, joinpath(paths.first, ".pkg/select_artifacts.jl"))
        @test haskey(files, joinpath(root, ".hidden/retained.jl"))
        @test !haskey(files, joinpath(root, "node_modules/generated.jl"))
        @test !haskey(files, joinpath(root, "audit output/generated.jl"))
        @test !any(path -> occursin("/loop/", path), keys(files))
        @test any(issue -> occursin("broken/Project.toml", issue) && occursin("parse failed", issue), inventory.issues)
        @test any(path -> occursin("symlink cycle", path), inventory.excluded)
        @test any(path -> occursin("analysis output directory", path), inventory.excluded)
        @test inventory.files == discover(root; output=joinpath(root, "audit output")).files
        excluded = discover(root; excludes=["loose scripts", "**/disconnected.jl"])
        @test !any(file -> occursin("loose scripts", file.path) || endswith(file.path, "disconnected.jl"), excluded.files)
        @test count(path -> occursin("explicit exclusion", path), excluded.excluded) == 2
    end
end

@testset "JuliaProject precedence and malformed metadata" begin
    mktempdir() do root
        discovery_project(root, "."; name="Preferred", uuid="75bf84b5-4bca-49c7-aa66-9564c35a4c6d")
        mv(joinpath(root, "Project.toml"), joinpath(root, "JuliaProject.toml"))
        discovery_file(root, "Project.toml", "not valid [ TOML")
        inventory = discover(root)
        @test only(inventory.projects).name == "Preferred"
        @test isempty(inventory.issues)
        @test any(item -> occursin("shadowed by JuliaProject.toml", item), inventory.excluded)
        discovery_file(root, "JuliaProject.toml", "uuid = 10\n")
        @test any(item -> occursin("must be strings", item), discover(root).issues)
        discovery_file(root, "JuliaProject.toml", "name = \"Broken\"\nuuid = \"invalid\"\n")
        @test any(item -> occursin("invalid project UUID", item), discover(root).issues)
    end
end

@testset "Output exclusion uses the same canonical root as discovery" begin
    mktempdir() do directory
        root = joinpath(directory, "actual")
        alias = joinpath(directory, "alias")
        mkpath(root)
        symlink(root, alias)
        source = discovery_file(root, "input.jl")
        output = joinpath(alias, "reports", "run")
        @test [file.path for file in discover(alias; output).files] == [source]
        discovery_file(output, "generated/context-entry.jl")
        inventory = discover(alias; output)
        @test [file.path for file in inventory.files] == [source]
        @test any(path -> occursin("analysis output directory", path), inventory.excluded)
        @test isempty(inventory.issues)
    end
end

@testset "Git tracked, ignored, untracked, and nested repositories" begin
    mktempdir() do root
        repository = LibGit2.init(root)
        try
            discovery_file(root, "ignored/retained.jl")
            LibGit2.add!(repository, "ignored/retained.jl")
            discovery_file(root, "ignored/hidden.jl")
            discovery_file(root, "generated/result.jl")
            discovery_file(root, "untracked file.jl")
            discovery_file(root, ".gitignore", "ignored/\ngenerated/\n")
            nested = joinpath(root, "nested repo")
            mkpath(nested)
            close(LibGit2.init(nested))
            discovery_file(nested, "child.jl")
            discovery_file(nested, "omitted.jl")
            discovery_file(nested, ".gitignore", "omitted.jl\n")
            included = Set(file.path for file in discover(root).files)
            @test joinpath(root, "ignored/retained.jl") in included
            @test !(joinpath(root, "ignored/hidden.jl") in included)
            @test !(joinpath(root, "generated/result.jl") in included)
            @test joinpath(root, "untracked file.jl") in included
            @test joinpath(nested, "child.jl") in included
            @test !(joinpath(nested, "omitted.jl") in included)
            @test length(discover(root; include_ignored=true).files) == 6
            @test [file.path for file in discover(root; include_untracked=false).files] == [joinpath(root, "ignored/retained.jl")]
            @test any(item -> occursin("Git ignored path", item), discover(root).excluded)
            # Starting below the Git root still respects its ignore rules.
            @test [file.path for file in discover(joinpath(root, "ignored")).files] == [joinpath(root, "ignored/retained.jl")]
            rm(joinpath(root, ".gitignore"))
            @test length(discover(root).files) == 5
            @test length(discover(root; include_untracked=false).files) == 1
            # Deleted tracked paths in the index are not source files to analyze.
            rm(joinpath(root, "ignored/retained.jl"))
            @test isempty(discover(root; include_untracked=false).files)
        finally
            close(repository)
        end
    end
end
