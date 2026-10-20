using Test, JETSweep, LibGit2, TOML, UUIDs

function discovery_write(root, relative, contents="nothing\n")
    path = joinpath(root, relative)
    mkpath(dirname(path))
    write(path, contents)
    return path
end

discovery_toml(; fields...) =
    sprint(io -> TOML.print(io, Dict{String,Any}(String(k) => v for (k, v) in fields); sorted=true))

"A package with a fresh UUID, and its default entry file unless `fields` choose another."
function discovery_package(root, relative, name; file="Project.toml", fields...)
    directory = joinpath(root, relative)
    discovery_write(directory, file, discovery_toml(; name, uuid=string(uuid4()), fields...))
    haskey(fields, :path) || haskey(fields, :entryfile) ||
        discovery_write(directory, joinpath("src", "$name.jl"), "module $name\nend\n")
    return directory
end

"""
Initialize a repository and track `files` in it, even where its ignore rules apply. The
user's global excludes file is replaced by an empty one, so only the fixture's rules apply.
"""
function discovery_git(directory, files...)
    repository = LibGit2.init(directory)
    try
        LibGit2.with(LibGit2.GitConfig(repository)) do config
            LibGit2.set!(config, "core.excludesfile", Sys.iswindows() ? "NUL" : "/dev/null")
        end
        isempty(files) || LibGit2.add!(repository, files...; flags=LibGit2.Consts.INDEX_ADD_FORCE)
    finally
        close(repository)
    end
end

discovery_relative(inventory, path) = isempty(path) ? "" : relpath(path, inventory.root)
discovery_files(inventory) = [discovery_relative(inventory, source.path) for source in inventory.sources]

"A `Dict` of `pairs` that fails on repeated keys instead of silently keeping the last."
function discovery_dict(pairs)
    dict = Dict(pairs)
    length(dict) == length(pairs) || error("repeated keys: $(first.(pairs))")
    return dict
end

"Root-relative paths of `inventory` mapped to `(kind, project, owner)`, also root-relative."
function discovery_placement(inventory)
    relative(path) = discovery_relative(inventory, path)
    return discovery_dict([relative(s.path) => (s.kind, relative(s.project), relative(s.owner))
                           for s in inventory.sources])
end

"Root-relative excluded paths mapped to the reason discovery gives."
function discovery_reasons(inventory)
    return discovery_dict(map(inventory.excluded) do item
        path, reason = match(r"^(.*) \(([^()]*)\)$", item).captures
        discovery_relative(inventory, path) => String(reason)
    end)
end

discovery_project_at(inventory, relative) =
    only(project for project in inventory.projects if discovery_relative(inventory, project.dir) == relative)

discovery_snapshot(inventory) = (inventory.root,
    [(p.dir, p.file, p.name, p.uuid, p.entry, p.extensions) for p in inventory.projects],
    [(s.path, s.kind, s.project, s.owner) for s in inventory.sources], inventory.excluded, inventory.issues)

const DISCOVERY_DATES = "ade2ca70-3891-5945-98fb-dc099432e06a"
const DISCOVERY_TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

@testset "Recursive inventory, source kinds and ownership" begin
    mktempdir() do root
        discovery_write(root, "Project.toml", discovery_toml(deps=Dict("Dates" => DISCOVERY_DATES)))
        discovery_write(root, "scripts/run.jl")
        alpha = discovery_package(root, "packages/Alpha", "Alpha"; deps=Dict("TOML" => DISCOVERY_TOML),
            weakdeps=Dict("Dates" => DISCOVERY_DATES),
            extensions=Dict("AlphaDatesExt" => "Dates", "AlphaToolsExt" => ["Dates", "TOML"]))
        for file in ("src/inner/helper.jl", "ext/AlphaDatesExt.jl", "ext/AlphaToolsExt/AlphaToolsExt.jl",
                     "ext/AlphaToolsExt/helper.jl", "test/runtests.jl", "test/group/case.jl", "docs/make.jl",
                     "build.jl", "README.md")
            discovery_write(alpha, file)
        end
        discovery_write(alpha, "test/Project.toml", "")
        discovery_write(alpha, "docs/Project.toml", discovery_toml(deps=Dict()))
        discovery_package(alpha, "src/Nested", "Nested")
        beta = discovery_package(root, "Beta", "Beta"; entryfile="lib/start.jl")
        foreach(file -> discovery_write(beta, file), ("lib/start.jl", "lib/helper.jl", "src/extra.jl"))
        gamma = discovery_package(root, "Gamma", "Gamma"; path="main.jl", entryfile="lib/other.jl")
        foreach(file -> discovery_write(gamma, file), ("main.jl", "lib/other.jl"))
        discovery_package(root, "one/Repeated", "Repeated")
        discovery_package(root, "nested folder/two/Repeated", "Repeated")

        inventory = discover(root)
        @test inventory.root == realpath(root)
        @test isempty(inventory.issues)
        @test isempty(inventory.excluded)
        @test [discovery_relative(inventory, p.file) for p in inventory.projects] == sort([
            "Project.toml", "packages/Alpha/Project.toml", "packages/Alpha/test/Project.toml",
            "packages/Alpha/docs/Project.toml", "packages/Alpha/src/Nested/Project.toml", "Beta/Project.toml",
            "Gamma/Project.toml", "one/Repeated/Project.toml", "nested folder/two/Repeated/Project.toml"])

        a, n = "packages/Alpha", "packages/Alpha/src/Nested"
        @test discovery_placement(inventory) == Dict(
            "scripts/run.jl" => (:script, ".", ""),
            "$a/src/Alpha.jl" => (:package, a, a),
            "$a/src/inner/helper.jl" => (:package, a, a),
            "$n/src/Nested.jl" => (:package, n, n),
            "$a/ext/AlphaDatesExt.jl" => (:extension, a, a),
            "$a/ext/AlphaToolsExt/AlphaToolsExt.jl" => (:extension, a, a),
            "$a/ext/AlphaToolsExt/helper.jl" => (:extension, a, a),
            "$a/test/runtests.jl" => (:test, "$a/test", a),
            "$a/test/group/case.jl" => (:test, "$a/test", a),
            "$a/docs/make.jl" => (:script, "$a/docs", a),
            "$a/build.jl" => (:script, a, a),
            "Beta/lib/start.jl" => (:package, "Beta", "Beta"),
            "Beta/lib/helper.jl" => (:script, "Beta", "Beta"),
            "Beta/src/extra.jl" => (:package, "Beta", "Beta"),
            "Gamma/main.jl" => (:package, "Gamma", "Gamma"),
            "Gamma/lib/other.jl" => (:script, "Gamma", "Gamma"),
            "one/Repeated/src/Repeated.jl" => (:package, "one/Repeated", "one/Repeated"),
            "nested folder/two/Repeated/src/Repeated.jl" =>
                (:package, "nested folder/two/Repeated", "nested folder/two/Repeated"))

        environment = discovery_project_at(inventory, ".")
        @test environment.name == environment.uuid == environment.entry == ""
        @test !JETSweep.ispackage(environment)
        alpha = discovery_project_at(inventory, a)
        @test JETSweep.ispackage(alpha) && alpha.name == "Alpha" && tryparse(UUID, alpha.uuid) !== nothing
        @test alpha.entry == joinpath(alpha.dir, "src", "Alpha.jl")
        @test alpha.extensions == Dict("AlphaDatesExt" => Dict("Dates" => DISCOVERY_DATES),
            "AlphaToolsExt" => Dict("Dates" => DISCOVERY_DATES, "TOML" => DISCOVERY_TOML))
        @test !JETSweep.ispackage(discovery_project_at(inventory, "$a/test"))
        entry(directory) = discovery_relative(inventory, discovery_project_at(inventory, directory).entry)
        @test entry("Beta") == "Beta/lib/start.jl"
        # Like Julia's loader, the older `path` key wins over `entryfile`.
        @test entry("Gamma") == "Gamma/main.jl"
        repeated = [discovery_project_at(inventory, directory)
                    for directory in ("one/Repeated", "nested folder/two/Repeated")]
        @test all(project -> project.name == "Repeated" && JETSweep.ispackage(project), repeated)
        @test allunique(project.uuid for project in repeated)
    end
    mktempdir() do root
        discovery_write(root, "loose.jl")
        inventory = discover(root)
        @test isempty(inventory.projects)
        @test discovery_placement(inventory) == Dict("loose.jl" => (:script, "", ""))
        @test cd(() -> discover("."), root).root == inventory.root
        @test_throws ArgumentError discover(joinpath(root, "loose.jl"))
        @test_throws ArgumentError discover(joinpath(root, "missing"))
    end
end

@testset "JuliaProject.toml takes precedence over Project.toml" begin
    mktempdir() do root
        preferred = discovery_package(root, "Preferred", "Preferred"; file="JuliaProject.toml")
        discovery_write(preferred, "Project.toml", "not valid [ TOML")
        discovery_package(root, "Only", "Only"; file="JuliaProject.toml")
        broken = discovery_package(root, "Broken", "Broken")
        discovery_write(broken, "JuliaProject.toml", "[deps\n")
        inventory = discover(root)
        @test [discovery_relative(inventory, p.file) for p in inventory.projects] ==
              ["Broken/JuliaProject.toml", "Only/JuliaProject.toml", "Preferred/JuliaProject.toml"]
        project = discovery_project_at(inventory, "Preferred")
        @test project.name == "Preferred" && JETSweep.ispackage(project)
        @test discovery_placement(inventory)["Preferred/src/Preferred.jl"] ==
              (:package, "Preferred", "Preferred")
        @test JETSweep.ispackage(discovery_project_at(inventory, "Only"))
        # The shadowed Project.toml is never read; the preferred file is, even when broken.
        @test startswith(only(inventory.issues),
                         joinpath(inventory.root, "Broken", "JuliaProject.toml") * ": cannot parse project: ")
        @test discovery_project_at(inventory, "Broken").name == ""
        @test discovery_placement(inventory)["Broken/src/Broken.jl"] == (:script, "Broken", "")
    end
end

@testset "Malformed project metadata is recorded as issues" begin
    mktempdir() do root
        id = string(uuid4())
        cases = [
            "parse" => ("[deps\n", "cannot parse project: "),
            "name" => ("name = 1\nuuid = \"$id\"\n", "project name and UUID must be strings"),
            "uuid" => ("name = \"Numeric\"\nuuid = 10\n", "project name and UUID must be strings"),
            "invalid" => ("name = \"Invalid\"\nuuid = \"invalid\"\n", "invalid project UUID \"invalid\""),
            "missing" => ("name = \"Missing\"\nuuid = \"$id\"\n",
                          "package entry file does not exist: src/Missing.jl"),
            "entryfile" => ("name = \"Elsewhere\"\nuuid = \"$id\"\nentryfile = \"lib/Elsewhere.jl\"\n",
                            "package entry file does not exist: lib/Elsewhere.jl"),
            "entry" => ("name = \"Entry\"\nuuid = \"$id\"\npath = 1\n",
                        "package entry file must be a string"),
            "deps" => ("[deps]\nBad = \"nope\"\n", "invalid UUID for Bad in [deps]"),
            "weakdeps" => ("weakdeps = 1\n", "[weakdeps] must be a table"),
            "extensions" => ("extensions = 1\n", "[extensions] must be a table"),
            "trigger" => ("[extensions]\nExt = 1\n", "extension Ext must name its trigger packages"),
            "undeclared" => ("[extensions]\nExt = [\"Absent\"]\n",
                             "extension Ext triggers lack declared UUIDs: Absent"),
        ]
        for (directory, (contents, _)) in cases
            discovery_write(root, joinpath(directory, "Project.toml"), contents)
        end
        # The fallback entry is not used when the declared one is missing, as in Julia's loader.
        discovery_write(root, "entryfile/src/Elsewhere.jl")
        inventory = discover(root)
        @test length(inventory.projects) == length(cases)
        @test issorted(inventory.issues) && allunique(inventory.issues)
        @test length(inventory.issues) == length(cases)
        for (directory, (_, message)) in cases
            prefix = joinpath(inventory.root, directory, "Project.toml") * ": "
            @test count(issue -> startswith(issue, prefix * message), inventory.issues) == 1
        end
        project(directory) = discovery_project_at(inventory, directory)
        @test project("parse").name == project("parse").uuid == ""
        @test project("name").name == project("name").uuid == ""
        @test project("uuid").name == "Numeric" && project("uuid").uuid == ""
        @test project("invalid").name == "Invalid" && project("invalid").uuid == ""
        @test project("missing").uuid == id && project("missing").entry == ""
        @test project("entryfile").entry == "" && project("entry").entry == ""
        @test !any(JETSweep.ispackage, inventory.projects)
        @test project("trigger").extensions == Dict()
        @test project("undeclared").extensions == Dict("Ext" => Dict("Absent" => ""))
    end
end

@testset "The nearest named project owns its sources, even with broken metadata" begin
    mktempdir() do root
        outer = discovery_package(root, "Outer", "Outer")
        discovery_write(outer, "vendor/Inner/Project.toml", "name = \"Inner\"\nuuid = \"invalid\"\n")
        foreach(file -> discovery_write(outer, "vendor/Inner/$file"), ("src/Inner.jl", "test/runtests.jl"))
        discovery_write(outer, "tools/Project.toml", "[deps\n")
        discovery_write(outer, "tools/src/tool.jl")
        discovery_write(outer, "bench/Project.toml", "name = 1\n")
        discovery_write(outer, "bench/test/run.jl")
        discovery_write(root, "App/Project.toml", "name = \"App\"\n")
        discovery_write(root, "App/src/App.jl")
        inventory = discover(root)
        inner = "Outer/vendor/Inner"
        @test discovery_placement(inventory) == Dict(
            "Outer/src/Outer.jl" => (:package, "Outer", "Outer"),
            "$inner/src/Inner.jl" => (:package, inner, inner),
            "$inner/test/runtests.jl" => (:test, inner, inner),
            "Outer/tools/src/tool.jl" => (:script, "Outer/tools", "Outer"),
            "Outer/bench/test/run.jl" => (:script, "Outer/bench", "Outer"),
            "App/src/App.jl" => (:package, "App", "App"))
        @test !JETSweep.ispackage(discovery_project_at(inventory, inner))
        @test !JETSweep.ispackage(discovery_project_at(inventory, "App"))
        prefixes = [joinpath(inventory.root, "Outer", file) * ": " * message for (file, message) in (
            "bench/Project.toml" => "project name and UUID must be strings",
            "tools/Project.toml" => "cannot parse project: ",
            "vendor/Inner/Project.toml" => "invalid project UUID \"invalid\"")]
        @test length(inventory.issues) == 3 && all(startswith.(inventory.issues, prefixes))
    end
end

@testset "Exclusion globs" begin
    mktempdir() do root
        files = ["keep.jl", "loose scripts/main.jl", "deep/loose scripts/main.jl", "pkg/src/top.jl",
                 "pkg/src/disconnected.jl", "pkg/src/sub/deep.jl", "pkg/src/sub/disconnected.jl",
                 "gen/generated/a.jl", "x/y/generated/b.jl", "build/out.jl", "pkgx/other.jl", "src/root.jl"]
        foreach(file -> discovery_write(root, file), files)
        kept(patterns...) = discovery_files(discover(root; exclude=collect(String, patterns)))
        without(excluded...) = sort(setdiff(files, excluded))
        package = filter(startswith("pkg/"), files)
        @test kept() == sort(files)
        @test kept("loose scripts") == without("loose scripts/main.jl", "deep/loose scripts/main.jl")
        @test kept("disconnected.jl") == without("pkg/src/disconnected.jl", "pkg/src/sub/disconnected.jl")
        @test kept("build/") == kept("build") == without("build/out.jl")
        @test kept("d*") == without("deep/loose scripts/main.jl", "pkg/src/disconnected.jl",
                                    "pkg/src/sub/deep.jl", "pkg/src/sub/disconnected.jl")
        @test kept("p?g") == without(package...)
        @test isempty(kept("*.jl"))
        @test kept("pkg/src/*.jl") == without("pkg/src/top.jl", "pkg/src/disconnected.jl")
        @test kept("src/*.jl") == without("src/root.jl")
        @test kept("pkg\\src\\*.jl") == kept("pkg/src/*.jl")
        @test kept("**/generated") == without("gen/generated/a.jl", "x/y/generated/b.jl")
        @test kept("**/disconnected.jl") == kept("disconnected.jl")
        @test kept("pkg/**") == without(package...)
        @test kept("pkg/**/deep.jl") == without("pkg/src/sub/deep.jl")
        @test kept("keep.jl", "src") == without("keep.jl", "src/root.jl", package...)
        inventory = discover(root; exclude=["loose scripts", "**/generated", "pkg/src/*.jl"])
        excluded = ["loose scripts", "deep/loose scripts", "gen/generated", "x/y/generated", "pkg/src/top.jl",
                    "pkg/src/disconnected.jl"]
        @test discovery_reasons(inventory) == Dict(path => "excluded by pattern" for path in excluded)
    end
end

@testset "Excluded directories keep their projects, without their sources or issues (Git: $git)" for git in (false, true)
    mktempdir() do directory
        root = realpath(directory)
        sibling = discovery_package(root, "Sibling", "Sibling")
        discovery_write(sibling, "test/runtests.jl")
        discovery_write(sibling, "vendor/Broken/Project.toml", "[deps\n")
        # What discovery leaves out for another reason stays out.
        discovery_package(sibling, "node_modules/Pruned", "Pruned")
        discovery_package(sibling, ".state/Hidden", "Hidden")
        discovery_package(sibling, "ignored/Ignored", "Ignored")
        discovery_package(root, "Kept", "Kept")
        if git
            discovery_write(root, ".gitignore", "ignored/\n")
            discovery_git(root)
        end
        inventory = discover(root; exclude=["Sibling"])
        @test discovery_files(inventory) == ["Kept/src/Kept.jl"]
        @test sort!([discovery_relative(inventory, p.dir) for p in inventory.projects]) ==
              (git ? ["Kept", "Sibling", "Sibling/vendor/Broken"] : ["Kept", "Sibling", "Sibling/ignored/Ignored", "Sibling/vendor/Broken"])
        @test JETSweep.ispackage(discovery_project_at(inventory, "Sibling"))
        @test isempty(inventory.issues)
        @test discovery_reasons(inventory) == Dict("Sibling" => "excluded by pattern")
        # An excluded project file is left out with the rest.
        inventory = discover(root; exclude=["Sibling/Project.toml"])
        @test !any(p -> p.dir == sibling, inventory.projects)
        @test discovery_placement(inventory)["Sibling/src/Sibling.jl"] == (:script, "", "")
        # A configuration's patterns are relative to its directory.
        config = JETSweep.Config(joinpath(root, ".JETSweep.toml"), ["Sibling/test", "Broken"], JETSweep.ContextRule[])
        ignored = git ? String[] : ["ignored/Ignored/src/Ignored.jl"]
        @test discovery_files(discover(sibling; config)) == [ignored; "src/Sibling.jl"]
        @test discovery_files(discover(sibling; exclude=["Sibling/test"])) == [ignored; "src/Sibling.jl"; "test/runtests.jl"]
        @test isempty(discover(sibling; config).issues) && !isempty(discover(sibling).issues)
    end
end

@testset "JETSweep._glob" begin
    matches(pattern, path) = occursin(JETSweep._glob(pattern), path)
    @test matches("*.jl", "a.jl") && !matches("*.jl", "a/b.jl") && !matches("*.jl", "a.jlx")
    @test matches("?.jl", "a.jl") && !matches("?.jl", "ab.jl") && !matches("a?b", "a/b")
    @test all(path -> matches("**/x.jl", path), ("x.jl", "a/x.jl", "a/b/x.jl"))
    @test !matches("**/x.jl", "ax.jl") && !matches("**/x.jl", "a/x.jl/b")
    @test matches("a/**", "a/b") && matches("a/**", "a/b/c")
    @test !matches("a/**", "a") && !matches("a/**", "ab/c")
    @test all(path -> matches("a/**/b", path), ("a/b", "a/x/b", "a/x/y/b"))
    @test !matches("a/**/b", "a/xb") && !matches("a/**/b", "a/x/bc")
    @test matches("**", "") && matches("**", "a/b/c")
    @test matches("a**", "a/b") && matches("**.jl", "a/b.jl")
    @test matches("b.jl", "b.jl") && !matches("b.jl", "ab.jl") && !matches("b.jl", "b.jl/c")
    @test !matches("b.jl", "bxjl")
    special = "a+b(c)|^\$x{1}[y].jl"
    @test matches(special, special) && !matches(special, "ab(c)x.jl") && !matches("[ab].jl", "a.jl")
    @test matches("a\\b\\*.jl", "a/b/c.jl")
    @test matches("dir with space/*.jl", "dir with space/x.jl")
    @test matches("é*/ü?.jl", "éa/üb.jl") && !matches("é*/ü?.jl", "éa/übc.jl")
end

@testset "Hidden, dependency and cache directories outside Git" begin
    mktempdir() do root
        for file in (".hidden/x.jl", ".jetsweep/run/worker.jl", ".dotfile.jl", "node_modules/x.jl",
                     "a/node_modules/y.jl", "__pycache__/z.jl", "a/__pycache__/w.jl", "kept.jl", "a/kept.jl")
            discovery_write(root, file)
        end
        inventory = discover(root)
        @test discovery_files(inventory) == [".dotfile.jl", "a/kept.jl", "kept.jl"]
        cache = "dependency or cache directory"
        @test discovery_reasons(inventory) == Dict(".hidden" => "hidden directory",
            ".jetsweep" => "hidden directory", "node_modules" => cache, "a/node_modules" => cache,
            "__pycache__" => cache, "a/__pycache__" => cache)
        @test discover(root; include_ignored=true).sources == inventory.sources
        @test discover(root; tracked_only=true).sources == inventory.sources
    end
end

@testset "Report output is excluded, also through an alias of the root" begin
    mktempdir() do directory
        root = mkpath(joinpath(directory, "actual"))
        alias = joinpath(directory, "alias")
        symlink(root, alias)
        discovery_write(root, "input.jl")
        output = joinpath(alias, "reports", "run")
        inventory = discover(alias; output)
        @test inventory.root == realpath(root)
        @test discovery_files(inventory) == ["input.jl"] && isempty(inventory.excluded)
        discovery_write(output, "generated/entry.jl")
        discovery_write(output, "environment/Project.toml", "")
        inventory = discover(alias; output)
        @test discovery_files(inventory) == ["input.jl"]
        @test isempty(inventory.projects) && isempty(inventory.issues)
        @test discovery_reasons(inventory) == Dict("reports/run" => "report output")
        @test discovery_files(discover(root; output)) == ["input.jl"]
        # A symlink to the report directory does not lead back into it.
        symlink(realpath(output), joinpath(root, "latest"))
        @test discovery_files(discover(alias; output)) == ["input.jl"]
    end
end

@testset "Directories tagged as caches are excluded, such as earlier reports (Git: $git)" for git in (false, true)
    mktempdir() do root
        discovery_write(root, "input.jl")
        # An earlier report: its tag, generated entries and environments.
        discovery_write(root, "reports/a/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n# A tag.\n")
        discovery_write(root, "reports/a/units/script-1/entry.jl")
        discovery_write(root, "reports/a/environments/1/env/Project.toml", "")
        # Only the signature marks a cache.
        discovery_write(root, "notes/CACHEDIR.TAG", "Signature: none\n")
        discovery_write(root, "notes/kept.jl")
        git && discovery_git(root, "reports/a/units/script-1/entry.jl")
        inventory = discover(root)
        @test discovery_files(inventory) == ["input.jl", "notes/kept.jl"]
        @test isempty(inventory.projects) && isempty(inventory.issues)
        @test discovery_reasons(inventory) == Dict("reports/a" => "tagged cache directory")
    end
end

@testset "Symlinks are never followed: cycles, aliases, outside targets and broken links" begin
    mktempdir() do sandbox
        root = mkpath(joinpath(sandbox, "root"))
        outside = discovery_write(sandbox, "outside/external.jl")
        discovery_write(root, "real/inner.jl")
        symlink(root, joinpath(root, "loop"))
        symlink(joinpath(root, "real"), joinpath(root, "real", "self"))
        symlink(joinpath(root, "real"), joinpath(root, "real alias"))
        symlink(dirname(outside), joinpath(root, "outside dir"))
        symlink(outside, joinpath(root, "outside.jl"))
        symlink(joinpath(root, "missing"), joinpath(root, "dangling"))
        symlink(joinpath(root, "missing.jl"), joinpath(root, "dangling.jl"))
        inventory = discover(root)
        @test discovery_files(inventory) == ["real/inner.jl"]
        @test discovery_reasons(inventory) == Dict(path => "symlink" for path in
            ("loop", "real/self", "real alias", "outside dir", "outside.jl", "dangling", "dangling.jl"))
        @test isempty(inventory.issues)
    end
    # Files are reported at their real paths, even when an alias is met before its target.
    mktempdir() do root
        discovery_write(root, "b/inner.jl")
        symlink(joinpath(root, "b"), joinpath(mkpath(joinpath(root, "a")), "link"))
        inventory = discover(root)
        @test discovery_files(inventory) == ["b/inner.jl"]
        @test discovery_reasons(inventory) == Dict("a/link" => "symlink")
        # Git rules apply to the real path, which an alias met first must not bypass.
        discovery_write(root, "b/dropped.jl")
        discovery_write(root, ".gitignore", "dropped.jl\n")
        discovery_git(root, "b/inner.jl")
        @test discovery_files(discover(root)) == ["b/inner.jl"]
    end
end

@testset "Unresolvable symlinks are excluded, not fatal" begin
    mktempdir() do sandbox
        root = mkpath(joinpath(sandbox, "root"))
        discovery_write(root, "kept.jl")
        symlink(joinpath(root, "cycle b"), joinpath(root, "cycle a"))
        symlink(joinpath(root, "cycle a"), joinpath(root, "cycle b"))
        locked = dirname(discovery_write(sandbox, "locked/target.jl"))
        symlink(joinpath(locked, "target.jl"), joinpath(root, "locked.jl"))
        chmod(locked, 0o000)
        try
            inventory = discover(root)
            @test discovery_files(inventory) == ["kept.jl"]
            @test issubset(("cycle a", "cycle b", "locked.jl"), keys(discovery_reasons(inventory)))
        finally
            chmod(locked, 0o755)
        end
    end
end

@testset "Git: tracked, ignored, untracked, hidden and nested repositories" begin
    mktempdir() do root
        nested = joinpath(root, "nested repo")
        for file in ("ignored/retained.jl", "ignored/dropped.jl", "generated/result.jl", "untracked file.jl",
                     "notes.jl", "partial/keep.jl", "partial/drop.jl", ".pkg/select_artifacts.jl",
                     ".claude/state.jl", "nested repo/child.jl", "nested repo/omitted.jl",
                     "nested repo/generated/kept.jl")
            discovery_write(root, file)
        end
        discovery_write(root, ".gitignore", "ignored/\ngenerated/\nnotes.jl\npartial/*\n!partial/keep.jl\n")
        discovery_write(nested, ".gitignore", "omitted.jl\n")
        discovery_git(root, "ignored/retained.jl", "notes.jl", ".pkg/select_artifacts.jl")
        discovery_git(nested, "child.jl")

        tracked = [".pkg/select_artifacts.jl", "ignored/retained.jl", "nested repo/child.jl", "notes.jl"]
        default = sort([tracked; "untracked file.jl"; "partial/keep.jl"; "nested repo/generated/kept.jl"])
        ignored = ["generated/result.jl", "ignored/dropped.jl", "nested repo/omitted.jl", "partial/drop.jl"]
        inventory = discover(root)
        @test discovery_files(inventory) == default
        @test discovery_reasons(inventory) == Dict("ignored/dropped.jl" => "Git-ignored path",
            "generated" => "Git-ignored path", "partial/drop.jl" => "Git-ignored path",
            ".claude" => "hidden directory", "nested repo/omitted.jl" => "Git-ignored path")
        @test isempty(inventory.issues)
        @test discovery_files(discover(root; include_ignored=true)) == sort([default; ignored])

        inventory = discover(root; tracked_only=true)
        @test discovery_files(inventory) == tracked
        untracked = "untracked Git path"
        @test discovery_reasons(inventory) == Dict(".claude" => "hidden directory",
            ".gitignore" => untracked, "untracked file.jl" => untracked, "generated" => untracked,
            "partial" => untracked, "ignored/dropped.jl" => untracked, "nested repo/.gitignore" => untracked,
            "nested repo/omitted.jl" => untracked, "nested repo/generated" => untracked)

        # Starting below a repository's root still applies its rules.
        inventory = discover(joinpath(root, "ignored"))
        @test discovery_files(inventory) == ["retained.jl"]
        @test discovery_reasons(inventory) == Dict("dropped.jl" => "Git-ignored path")
        @test discovery_files(discover(joinpath(root, "partial"))) == ["keep.jl"]
        @test discovery_files(discover(nested)) == ["child.jl", "generated/kept.jl"]

        # Deleted tracked files stay in the index but are no sources.
        rm(joinpath(root, "ignored", "retained.jl"))
        rm(joinpath(nested, "child.jl"))
        @test discovery_files(discover(root; tracked_only=true)) == [".pkg/select_artifacts.jl", "notes.jl"]
        @test discovery_files(discover(root)) ==
              filter(!in(("ignored/retained.jl", "nested repo/child.jl")), default)
    end
end

@testset "Repositories linked by .git files and unreadable repositories" begin
    mktempdir() do sandbox
        root = mkpath(joinpath(sandbox, "root"))
        linked = joinpath(root, "linked")
        foreach(file -> discovery_write(linked, file), ("child.jl", "omitted.jl", ".tool/state.jl"))
        discovery_write(linked, ".gitignore", "omitted.jl\n")
        discovery_git(linked)
        mv(joinpath(linked, ".git"), joinpath(sandbox, "linked.git"))
        write(joinpath(linked, ".git"), "gitdir: $(joinpath(sandbox, "linked.git"))\n")
        foreach(file -> discovery_write(root, file), ("omitted.jl", "broken/x.jl", "broken/omitted.jl"))
        discovery_write(root, "broken/.gitignore", "omitted.jl\n")
        mkpath(joinpath(root, "broken", ".git"))
        inventory = discover(root)
        @test discovery_files(inventory) ==
              ["broken/omitted.jl", "broken/x.jl", "linked/child.jl", "omitted.jl"]
        @test discovery_reasons(inventory) ==
              Dict("linked/omitted.jl" => "Git-ignored path", "linked/.tool" => "hidden directory")
        @test startswith(only(inventory.issues), joinpath(inventory.root, "broken") *
                         ": cannot read Git repository, so its ignore rules are not applied: ")
        @test discovery_files(discover(linked)) == ["child.jl"]
    end
end

@testset "Unreadable directories are recorded as issues (Git: $git)" for git in (false, true)
    mktempdir() do root
        discovery_write(root, "open.jl")
        git && discovery_git(root, "open.jl")
        locked = mkpath(joinpath(root, "locked"))
        chmod(locked, 0o000)
        try
            denied = try
                readdir(locked)
                false
            catch
                true
            end
            inventory = discover(root)
            @test discovery_files(inventory) == ["open.jl"]
            issue = joinpath(inventory.root, "locked") * ": cannot list directory: "
            # Permissions do not deny a superuser, who then has no issue to record.
            @test startswith(only(inventory.issues), issue) skip=!denied
        finally
            chmod(locked, 0o755)
        end
    end
end

@testset "Discovery is deterministic" begin
    mktempdir() do directory
        root = mkpath(joinpath(directory, "root"))
        for name in ("Zeta", "Alpha", "Mu")
            package = discovery_package(root, "packages/$name", name)
            foreach(file -> discovery_write(package, file), ("test/runtests.jl", "src/b.jl", "src/a.jl"))
        end
        discovery_write(root, "broken/Project.toml", "[deps\n")
        discovery_write(root, "invalid/Project.toml", "name = \"Invalid\"\nuuid = \"x\"\n")
        foreach(file -> discovery_write(root, file), ("z.jl", "a.jl", "node_modules/x.jl", ".cache/y.jl"))
        symlink(root, joinpath(root, "loop"))
        symlink(root, joinpath(directory, "alias"))
        inventory = discover(root)
        @test issorted([p.file for p in inventory.projects]) && issorted([s.path for s in inventory.sources])
        @test issorted(inventory.excluded) && issorted(inventory.issues) && length(inventory.issues) == 2
        snapshot = discovery_snapshot(inventory)
        @test discovery_snapshot(discover(root)) == snapshot
        @test discovery_snapshot(discover(joinpath(directory, "alias"))) == snapshot
    end
end
