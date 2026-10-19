using Test, JETSweep, Pkg, TOML, UUIDs, LibGit2

function _environments_write(file, data)
    mkpath(dirname(file))
    open(io -> TOML.print(io, data; sorted=true), file, "w")
    return file
end

function _environments_package(root, name; uuid=string(uuid4()), version="1.0.0", body="value() = 42", fields...)
    directory = joinpath(root, name)
    project = Dict{String,Any}("name" => name, "uuid" => uuid, "version" => version)
    for (key, value) in fields
        project[string(key)] = value
    end
    _environments_write(joinpath(directory, "Project.toml"), project)
    mkpath(joinpath(directory, "src"))
    write(joinpath(directory, "src", "$name.jl"), "module $name\n$body\nend\n")
    return directory, uuid
end

# The user's depot stays first: preparation's re-resolve fallback re-adds the analyzer's Git-sourced
# packages, which is offline only with their clones in that depot's clone cache.
_environments_sandbox(f) = mktempdir(root -> mktempdir(envs -> f(root, envs)))

_environments_context(project, owner=project; test=false, triggers=Dict{String,String}()) =
    JETSweep.Context(project, owner, test, triggers)

_environments_prepare(context, directory; instantiate=false) =
    JETSweep.prepare(context, directory; instantiate, precompile=false)

_environments_ready(directory) = JETSweep.Environment(:ready, directory, "")

_environments_project(environment) = TOML.parsefile(joinpath(environment.dir, "Project.toml"))
_environments_preferences(environment) = TOML.parsefile(joinpath(environment.dir, "LocalPreferences.toml"))
_environments_manifest(environment) = Pkg.Types.read_manifest(joinpath(environment.dir, "Manifest.toml"))
_environments_path(environment, uuid) =
    abspath(environment.dir, _environments_manifest(environment)[UUID(uuid)].path)

"The entry named `name` in the manifest of the project JETSweep, and so the analyzer, was loaded from."
_environments_tool(name) =
    only(entry for entry in values(Pkg.Types.EnvCache(JETSweep.tool_project()).manifest) if entry.name == name)

"Every file below `root` with its contents, to show that preparation writes none of them."
function _environments_snapshot(root)
    files = Dict{String,Vector{UInt8}}()
    for (directory, _, names) in walkdir(root), name in names
        files[joinpath(directory, name)] = read(joinpath(directory, name))
    end
    return files
end

"""
Run `code` in a fresh Julia process whose only environments are the prepared one and the stdlib. Like the
workers, it uses default code generation flags and existing package images, so it writes no caches.
"""
function _environments_run(environment, code)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    command = `$julia --startup-file=no --compiled-modules=existing --project=$(environment.dir) -e $code`
    return readchomp(addenv(command, "JULIA_LOAD_PATH" => "@:@stdlib"))
end

function _environments_commit(repository, message)
    signature = LibGit2.Signature("JETSweep fixture", "fixture@example.invalid")
    LibGit2.add!(repository, "*")
    return string(LibGit2.commit(repository, message; author=signature, committer=signature))
end

function _environments_seed(file, entries...)
    manifest = Pkg.Types.Manifest(julia_version=VERSION, manifest_format=v"2.0")
    foreach(entry -> manifest[entry.uuid] = entry, entries)
    Pkg.Types.write_manifest(manifest, file)
    return file
end

_environments_entry(name, uuid; version=v"1.0.0", fields...) =
    Pkg.Types.PackageEntry(; name, uuid=UUID(uuid), version, fields...)

_environments_test_uuid() = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

@testset "package context: merged scratch environment with the analyzer" begin
    _environments_sandbox() do root, envs
        helper, helper_uuid = _environments_package(root, "PlainHelper")
        parent, parent_uuid = _environments_package(root, "PlainParent"; deps=Dict("PlainHelper" => helper_uuid),
            sources=Dict("PlainHelper" => Dict("path" => "../PlainHelper")),
            body="using PlainHelper\nvalue() = PlainHelper.value()")
        write(joinpath(parent, "LocalPreferences.toml"), "[PlainParent]\nbackend = \"cpu\"\n")
        before = _environments_snapshot(root)
        state = (Base.active_project(), copy(LOAD_PATH), copy(DEPOT_PATH))
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "plain"))
        @test environment == _environments_ready(joinpath(envs, "plain"))
        @test _environments_snapshot(root) == before
        @test (Base.active_project(), LOAD_PATH, DEPOT_PATH) == state

        project = _environments_project(environment)
        jetls, runner, core = _environments_tool.(("JETLS", "TestRunner", "JETLSCore"))
        @test project["deps"] == Dict("PlainParent" => parent_uuid, "PlainHelper" => helper_uuid,
                                      "JETLS" => string(jetls.uuid), "TestRunner" => string(runner.uuid))
        @test project["extras"] == Dict("JETLSCore" => string(core.uuid))
        @test project["sources"]["PlainParent"] == Dict("path" => parent)
        @test project["sources"]["PlainHelper"] == Dict("path" => helper)
        @test project["sources"]["JETLS"] == Dict("url" => jetls.repo.source, "rev" => jetls.repo.rev)
        @test project["sources"]["TestRunner"] ==
              Dict("url" => runner.repo.source, "rev" => runner.repo.rev, "subdir" => runner.repo.subdir)
        @test _environments_path(environment, parent_uuid) == parent
        @test _environments_path(environment, helper_uuid) == helper
        @test _environments_manifest(environment)[jetls.uuid].tree_hash == jetls.tree_hash
        @test _environments_preferences(environment) ==
              Dict("JETLSCore" => Dict("JETLS_DEV_MODE" => true), "PlainParent" => Dict("backend" => "cpu"))
        @test _environments_run(environment, """
            using PlainParent
            print(PlainParent.value(), ' ', Base.get_preferences(Base.UUID("$(core.uuid)"))["JETLS_DEV_MODE"],
                  ' ', Base.get_preferences(Base.UUID("$parent_uuid"))["backend"])
            """) == "42 true cpu"
    end
end

@testset "only an empty or new directory is prepared" begin
    _environments_sandbox() do root, envs
        parent, _ = _environments_package(root, "RefusedParent")
        context = _environments_context(parent)
        occupied = mkpath(joinpath(envs, "occupied"))
        write(joinpath(occupied, "keep.txt"), "keep")
        environment = _environments_prepare(context, occupied)
        @test environment.status === :failed
        @test environment.dir == occupied
        @test occursin("preparation directory is not empty: $occupied", environment.message)
        @test readdir(occupied) == ["keep.txt"]
        @test read(joinpath(occupied, "keep.txt"), String) == "keep"

        empty = mkpath(joinpath(envs, "empty"))
        @test _environments_prepare(context, empty) == _environments_ready(empty)
        relative = cd(() -> _environments_prepare(context, "relative"), envs)
        @test relative == _environments_ready(joinpath(realpath(envs), "relative"))
    end
end

@testset "test context merges the test target and test/Project.toml" begin
    _environments_sandbox() do root, envs
        extra, extra_uuid = _environments_package(root, "TargetHelper")
        dedicated, dedicated_uuid = _environments_package(root, "DedicatedHelper")
        parent, parent_uuid = _environments_package(root, "TestedParent";
            extras=Dict("TargetHelper" => extra_uuid, "Test" => _environments_test_uuid()),
            targets=Dict("test" => ["TargetHelper", "Test"]),
            sources=Dict("TargetHelper" => Dict("path" => "../TargetHelper")))
        _environments_write(joinpath(parent, "test", "Project.toml"), Dict(
            "deps" => Dict("DedicatedHelper" => dedicated_uuid, "TestedParent" => parent_uuid),
            "sources" => Dict("DedicatedHelper" => Dict("path" => "../../DedicatedHelper"),
                              "TestedParent" => Dict("path" => ".."))))
        before = _environments_snapshot(root)
        context = _environments_context(joinpath(parent, "test"), parent; test=true)
        environment = _environments_prepare(context, joinpath(envs, "test"))
        @test environment == _environments_ready(joinpath(envs, "test"))
        @test _environments_snapshot(root) == before
        @test issubset(["TestedParent", "TargetHelper", "DedicatedHelper", "Test"],
                       keys(_environments_project(environment)["deps"]))
        @test _environments_run(environment, """
            using TestedParent, TargetHelper, DedicatedHelper, Test
            print(TargetHelper.value() + DedicatedHelper.value())
            """) == "84"

        package = _environments_prepare(_environments_context(parent), joinpath(envs, "package"))
        @test package == _environments_ready(joinpath(envs, "package"))
        project = _environments_project(package)
        @test !any(name -> haskey(project["deps"], name), ["TargetHelper", "DedicatedHelper", "Test"])
        @test project["extras"]["TargetHelper"] == extra_uuid
        @test !haskey(project["sources"], "TargetHelper")
    end
end

@testset "test projects named either way, inside or outside the package's workspace" begin
    _environments_sandbox() do root, envs
        helper, helper_uuid = _environments_package(root, "TestOnlyHelper")
        layouts = (("ConventionTested", "Project.toml", (;)), ("JuliaProjectTested", "JuliaProject.toml", (;)),
                   ("WorkspaceTested", "Project.toml", (; workspace=Dict("projects" => ["test"]))))
        for (name, file, fields) in layouts
            parent, parent_uuid = _environments_package(root, name; fields...)
            deps = Dict(name => parent_uuid, "TestOnlyHelper" => helper_uuid, "Test" => _environments_test_uuid())
            _environments_write(joinpath(parent, "test", file), Dict("deps" => deps,
                "sources" => Dict("TestOnlyHelper" => Dict("path" => "../../TestOnlyHelper"))))
        end
        before = _environments_snapshot(root)
        for (name, _, _) in layouts, instantiate in (false, true)
            parent = joinpath(root, name)
            directory = joinpath(envs, "$name-$instantiate")
            context = _environments_context(joinpath(parent, "test"), parent; test=true)
            environment = _environments_prepare(context, directory; instantiate)
            @test environment == _environments_ready(directory)
            JETSweep.ready(environment) || continue
            code = "using $name, TestOnlyHelper, Test; print(TestOnlyHelper.value())"
            @test _environments_run(environment, code) == "42"
        end
        @test _environments_snapshot(root) == before
    end
end

@testset "extension triggers become dependencies" begin
    _environments_sandbox() do root, envs
        first, first_uuid = _environments_package(root, "FirstTrigger")
        second, second_uuid = _environments_package(root, "SecondTrigger")
        triggers = Dict("FirstTrigger" => first_uuid, "SecondTrigger" => second_uuid)
        parent, _ = _environments_package(root, "ExtendedParent"; weakdeps=triggers, extras=triggers,
            extensions=Dict("BothExt" => ["FirstTrigger", "SecondTrigger"]),
            sources=Dict("FirstTrigger" => Dict("path" => "../FirstTrigger"),
                         "SecondTrigger" => Dict("path" => "../SecondTrigger")))
        write(joinpath(mkpath(joinpath(parent, "ext")), "BothExt.jl"),
              "module BothExt\nusing ExtendedParent, FirstTrigger, SecondTrigger\nvalue() = 84\nend\n")
        environment = _environments_prepare(_environments_context(parent; triggers), joinpath(envs, "extension"))
        @test environment == _environments_ready(joinpath(envs, "extension"))
        project = _environments_project(environment)
        @test project["deps"]["FirstTrigger"] == first_uuid
        @test project["deps"]["SecondTrigger"] == second_uuid
        @test !haskey(project["extras"], "FirstTrigger")
        @test _environments_run(environment, """
            using ExtendedParent, FirstTrigger, SecondTrigger
            print(Base.get_extension(ExtendedParent, :BothExt).value())
            """) == "84"

        package = _environments_prepare(_environments_context(parent), joinpath(envs, "package"))
        @test package == _environments_ready(joinpath(envs, "package"))
        @test !haskey(_environments_project(package)["deps"], "FirstTrigger")
        @test _environments_project(package)["extras"]["FirstTrigger"] == first_uuid

        wrong = string(uuid4())
        context = _environments_context(parent; triggers=Dict("FirstTrigger" => wrong))
        failure = _environments_prepare(context, joinpath(envs, "wrong"))
        @test failure.status === :failed
        @test occursin("UUID mismatch for FirstTrigger at $first: expected $wrong, found $first_uuid",
                       failure.message)
    end
end

@testset "script contexts use the nearest environment only" begin
    _environments_sandbox() do root, envs
        owned, owned_uuid = _environments_package(root, "OwnedHelper")
        _, script_uuid = _environments_package(root, "ScriptHelper")
        parent, _ = _environments_package(root, "ScriptOwner"; deps=Dict("OwnedHelper" => owned_uuid),
            sources=Dict("OwnedHelper" => Dict("path" => "../OwnedHelper")))
        scripts = joinpath(parent, "scripts")
        _environments_write(joinpath(scripts, "Project.toml"), Dict("deps" => Dict("ScriptHelper" => script_uuid),
            "sources" => Dict("ScriptHelper" => Dict("path" => "../../ScriptHelper"))))
        environment = _environments_prepare(_environments_context(scripts, ""), joinpath(envs, "script"))
        @test environment == _environments_ready(joinpath(envs, "script"))
        @test keys(_environments_project(environment)["deps"]) == Set(["ScriptHelper", "JETLS", "TestRunner"])
        @test _environments_run(environment, """
            using ScriptHelper
            print(ScriptHelper.value(), ' ', Base.identify_package("ScriptOwner") === nothing)
            """) == "42 true"

        # A script outside every project still gets the analyzer.
        standalone = _environments_prepare(_environments_context("", ""), joinpath(envs, "standalone"))
        @test standalone == _environments_ready(joinpath(envs, "standalone"))
        @test keys(_environments_project(standalone)["deps"]) == Set(["JETLS", "TestRunner"])

        bare = mkpath(joinpath(root, "bare"))
        failure = _environments_prepare(_environments_context(bare, ""), joinpath(envs, "bare"))
        @test failure.status === :failed
        @test occursin("no Julia project at $bare", failure.message)
    end
end

@testset "missing dependencies fail when downloads are disabled" begin
    _environments_sandbox() do root, envs
        absent = string(uuid4())
        _environments_package(root, "UnregisteredSibling"; uuid=absent)   # present, but nothing locates it
        scripts = joinpath(root, "scripts")
        _environments_write(joinpath(scripts, "Project.toml"),
                            Dict("deps" => Dict("UnregisteredSibling" => absent)))
        direct = _environments_prepare(_environments_context(scripts, ""), joinpath(envs, "direct"))
        @test direct.status === :failed
        @test occursin("UnregisteredSibling ($absent)", direct.message)
        @test occursin("downloads are disabled", direct.message)

        ghost = string(uuid4())
        _, helper_uuid = _environments_package(root, "GhostlyHelper"; deps=Dict("Ghost" => ghost))
        parent, _ = _environments_package(root, "GhostlyParent"; deps=Dict("GhostlyHelper" => helper_uuid),
            sources=Dict("GhostlyHelper" => Dict("path" => "../GhostlyHelper")))
        transitive = _environments_prepare(_environments_context(parent), joinpath(envs, "transitive"))
        @test transitive.status === :failed
        @test occursin("Ghost ($ghost), needed by GhostlyHelper", transitive.message)
        @test occursin("downloads are disabled", transitive.message)

        # Locked by a manifest, but never downloaded into any depot.
        locked, unfetched_uuid = joinpath(root, "locked"), string(uuid4())
        _environments_write(joinpath(locked, "Project.toml"),
                            Dict("deps" => Dict("NeverFetched" => unfetched_uuid)))
        tree_hash = Base.SHA1(repeat("ab", 20))
        _environments_seed(joinpath(locked, "Manifest.toml"),
                           _environments_entry("NeverFetched", unfetched_uuid; tree_hash))
        unfetched = _environments_prepare(_environments_context(locked, ""), joinpath(envs, "unfetched"))
        @test unfetched.status === :failed
        @test occursin("not installed", unfetched.message)
        @test occursin("NeverFetched", unfetched.message)
        @test occursin("downloads are disabled", unfetched.message)
    end
end

@testset "invalid contexts fail with their cause" begin
    _environments_sandbox() do root, envs
        failure(context, name) = _environments_prepare(context, joinpath(envs, name))
        helper_uuid = string(uuid4())
        dependent(name, source) = first(_environments_package(root, name;
            deps=Dict("Helper" => helper_uuid), sources=Dict("Helper" => Dict("path" => source))))
        impostor, _ = _environments_package(root, "Impostor"; uuid=helper_uuid)

        moved = failure(_environments_context(dependent("MovedParent", "../Gone")), "moved")
        @test moved.status === :failed
        @test occursin("path dependency Helper ($helper_uuid) is missing at $(joinpath(root, "Gone"))",
                       moved.message)

        renamed = failure(_environments_context(dependent("RenamedParent", "../Impostor")), "renamed")
        @test renamed.status === :failed
        @test occursin("package name mismatch at $impostor: expected Helper, found Impostor", renamed.message)

        _environments_write(joinpath(root, "Anonymous", "Project.toml"), Dict("name" => "Helper"))
        anonymous = failure(_environments_context(dependent("AnonymousParent", "../Anonymous")), "anonymous")
        @test anonymous.status === :failed
        @test occursin("path dependency at $(joinpath(root, "Anonymous")) (Helper) has no UUID", anonymous.message)

        conflicted, _ = _environments_package(root, "ConflictedParent"; deps=Dict("Helper" => helper_uuid))
        _environments_write(joinpath(conflicted, "test", "Project.toml"),
                            Dict("deps" => Dict("Helper" => string(uuid4()))))
        conflict = failure(_environments_context(joinpath(conflicted, "test"), conflicted; test=true),
                           "conflicted")
        @test conflict.status === :failed
        @test occursin("conflicting UUIDs for Helper", conflict.message)

        sourced = dependent("SourcedParent", "../A")
        test_sources = Dict("Helper" => Dict("path" => "../../B"))
        _environments_write(joinpath(sourced, "test", "Project.toml"),
                            Dict("deps" => Dict("Helper" => helper_uuid), "sources" => test_sources))
        sources = failure(_environments_context(joinpath(sourced, "test"), sourced; test=true), "sourced")
        @test sources.status === :failed
        @test occursin("conflicting [sources] for Helper", sources.message)

        targeted, _ = _environments_package(root, "TargetedParent"; targets=Dict("test" => ["Undeclared"]))
        target = failure(_environments_context(targeted; test=true), "targeted")
        @test target.status === :failed
        @test occursin("`Undeclared` in target `test`", target.message)   # Pkg's own validation
    end
end

@testset "workspaces and the active versioned manifest seed resolution" begin
    _environments_sandbox() do root, envs
        member, member_uuid = _environments_package(root, "WorkspaceMember")
        seeded, seeded_uuid = _environments_package(joinpath(root, "vendor"), "SeededHelper")
        parent, parent_uuid = _environments_package(root, "WorkspaceParent";
            deps=Dict("WorkspaceMember" => member_uuid, "SeededHelper" => seeded_uuid),
            preferences=Dict("WorkspaceParent" => Dict("level" => "member")))
        _environments_write(joinpath(root, "Project.toml"), Dict(
            "workspace" => Dict("projects" => ["WorkspaceParent", "WorkspaceMember"]),
            "preferences" => Dict("WorkspaceParent" => Dict("backend" => "workspace", "level" => "root"))))
        # Only Julia's active version-specific manifest may seed preparation; only it locates SeededHelper.
        _environments_seed(joinpath(root, "JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml"),
                           _environments_entry("SeededHelper", seeded_uuid; path="vendor/SeededHelper"))
        write(joinpath(root, "Manifest.toml"), "invalid = [\n")
        before = _environments_snapshot(root)
        code = """
            using WorkspaceParent, WorkspaceMember, SeededHelper
            preferences = Base.get_preferences(Base.UUID("$parent_uuid"))
            print(WorkspaceMember.value() + SeededHelper.value(), ' ', preferences["backend"], ' ',
                  preferences["level"])
            """
        offline = _environments_prepare(_environments_context(parent), joinpath(envs, "offline"))
        @test offline == _environments_ready(joinpath(envs, "offline"))
        @test _environments_snapshot(root) == before
        @test _environments_path(offline, seeded_uuid) == seeded
        @test _environments_path(offline, member_uuid) == member
        @test _environments_preferences(offline)["WorkspaceParent"] ==
              Dict("backend" => "workspace", "level" => "member")
        @test _environments_run(offline, code) == "84 workspace member"

        resolved = _environments_prepare(_environments_context(parent), joinpath(envs, "resolved");
                                         instantiate=true)
        @test resolved == _environments_ready(joinpath(envs, "resolved"))
        @test _environments_snapshot(root) == before
        @test _environments_path(resolved, seeded_uuid) == seeded
        @test _environments_run(resolved, code) == "84 workspace member"
    end
end

@testset "stale path-dependency metadata is refreshed" begin
    _environments_sandbox() do root, envs
        helper, helper_uuid = _environments_package(root, "FreshHelper")
        parent, parent_uuid = _environments_package(root, "StaleParent"; deps=Dict("FreshHelper" => helper_uuid),
            sources=Dict("FreshHelper" => Dict("path" => "../FreshHelper")))
        _environments_seed(joinpath(parent, "Manifest.toml"),
                           _environments_entry("StaleParent", parent_uuid; path=".", version=v"0.1.0"))
        before = _environments_snapshot(root)
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "refreshed"))
        @test environment == _environments_ready(joinpath(envs, "refreshed"))
        @test _environments_snapshot(root) == before
        entry = _environments_manifest(environment)[UUID(parent_uuid)]
        @test entry.deps == Dict("FreshHelper" => UUID(helper_uuid))
        @test entry.version == v"1.0.0"
        @test _environments_path(environment, parent_uuid) == parent
        @test _environments_path(environment, helper_uuid) == helper
    end
end

@testset "explicit sources override stale manifest locations" begin
    _environments_sandbox() do root, envs
        helper, helper_uuid = _environments_package(root, "ChosenHelper")
        parent, _ = _environments_package(root, "SourceParent"; deps=Dict("ChosenHelper" => helper_uuid),
            sources=Dict("ChosenHelper" => Dict("path" => "../ChosenHelper")))
        orphan = string(uuid4())
        _environments_seed(joinpath(parent, "Manifest.toml"),
                           _environments_entry("ChosenHelper", helper_uuid; path="../obsolete-checkout"),
                           _environments_entry("UnusedOldPackage", orphan; path="../missing-orphan"))
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "override"))
        @test environment == _environments_ready(joinpath(envs, "override"))
        @test _environments_path(environment, helper_uuid) == helper
        @test !haskey(_environments_manifest(environment), UUID(orphan))
        @test _environments_run(environment, "using ChosenHelper; print(ChosenHelper.value())") == "42"
    end
end

@testset "URL sources replace stale checkouts and keep exact commits" begin
    _environments_sandbox() do root, envs
        repository = joinpath(root, "UrlRepository")
        _, trigger_uuid = _environments_package(repository, "UrlTrigger")
        revision = LibGit2.with(repo -> _environments_commit(repo, "Fixture"), LibGit2.init(repository))
        parent, _ = _environments_package(root, "UrlParent"; deps=Dict("UrlTrigger" => trigger_uuid),
            sources=Dict("UrlTrigger" =>
                         Dict("url" => "../UrlRepository", "rev" => revision, "subdir" => "UrlTrigger")))
        _environments_seed(joinpath(parent, "Manifest.toml"),
                           _environments_entry("UrlTrigger", trigger_uuid; path="../obsolete-checkout"))
        before = _environments_snapshot(root)
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "url"); instantiate=true)
        @test environment == _environments_ready(joinpath(envs, "url"))
        @test _environments_snapshot(root) == before
        entry = _environments_manifest(environment)[UUID(trigger_uuid)]
        @test entry.path === nothing
        @test (entry.repo.source, entry.repo.rev, entry.repo.subdir) == (repository, revision, "UrlTrigger")
        @test _environments_run(environment, "using UrlParent, UrlTrigger; print(UrlTrigger.value())") == "42"
        # Only a local repository is located relative to its project; remote URLs are kept verbatim.
        for url in ("https://example.invalid/R.jl", "git@example.invalid:org/R.jl.git", "file:///srv/R.jl")
            @test JETSweep._source(Dict("url" => url), parent) == Dict("url" => url)
        end
    end
end

@testset "standard library dependencies resolve offline" begin
    _environments_sandbox() do root, envs
        dates, printf = "ade2ca70-3891-5945-98fb-dc099432e06a", "de0858da-6303-5e67-8744-51eddeeeb8d7"
        parent, _ = _environments_package(root, "StdlibParent"; deps=Dict("Dates" => dates),
            body="using Dates\nvalue() = Dates.year(Date(2026, 10, 19))")
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "stdlib"))
        @test environment == _environments_ready(joinpath(envs, "stdlib"))
        manifest = _environments_manifest(environment)
        @test haskey(manifest, UUID(dates)) && haskey(manifest, UUID(printf))
        @test manifest[UUID(dates)].path === nothing
        @test _environments_run(environment, "using StdlibParent; print(StdlibParent.value())") == "2026"
    end
end

@testset "preference precedence and __clear__" begin
    _environments_sandbox() do root, envs
        exported = Dict("backend" => "exported", "clear_me" => true, "exported_only" => 1)
        parent, parent_uuid = _environments_package(root, "PreferenceParent";
                                                    preferences=Dict("PreferenceParent" => exported))
        write(joinpath(parent, "LocalPreferences.toml"),
              "[PreferenceParent]\nbackend = \"local\"\nlocal_only = true\n")
        write(joinpath(parent, "JuliaLocalPreferences.toml"),
              "[PreferenceParent]\nbackend = \"julia-local\"\n__clear__ = [\"clear_me\"]\n")
        before = _environments_snapshot(root)
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "julia-local"))
        @test environment == _environments_ready(joinpath(envs, "julia-local"))
        @test _environments_snapshot(root) == before
        preferences = _environments_preferences(environment)["PreferenceParent"]
        @test preferences["backend"] == "julia-local"
        @test preferences["exported_only"] == 1
        @test !haskey(preferences, "clear_me")
        @test !haskey(preferences, "local_only")   # JuliaLocalPreferences.toml shadows LocalPreferences.toml
        @test _environments_run(environment, """
            preferences = Base.get_preferences(Base.UUID("$parent_uuid"))
            print(preferences["backend"], ' ', preferences["exported_only"], ' ', haskey(preferences, "clear_me"))
            """) == "julia-local 1 false"

        rm(joinpath(parent, "JuliaLocalPreferences.toml"))
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "local"))
        @test environment == _environments_ready(joinpath(envs, "local"))
        @test _environments_preferences(environment)["PreferenceParent"] ==
              merge(exported, Dict("backend" => "local", "local_only" => true))
    end
end

@testset "preferences bind transitive packages through [extras]" begin
    _environments_sandbox() do root, envs
        dependency, dependency_uuid = _environments_package(root, "PreferenceDependency")
        _, helper_uuid = _environments_package(root, "PreferenceHelper";
            deps=Dict("PreferenceDependency" => dependency_uuid),
            sources=Dict("PreferenceDependency" => Dict("path" => "../PreferenceDependency")))
        parent, _ = _environments_package(root, "TransitiveParent"; deps=Dict("PreferenceHelper" => helper_uuid),
            extras=Dict("PreferenceDependency" => dependency_uuid),
            sources=Dict("PreferenceHelper" => Dict("path" => "../PreferenceHelper")))
        write(joinpath(parent, "LocalPreferences.toml"),
              "[PreferenceDependency]\nmode = \"target\"\n\n[JETLSCore]\nJETLS_DEV_MODE = false\nkept = \"yes\"\n")
        environment = _environments_prepare(_environments_context(parent), joinpath(envs, "transitive"))
        @test environment == _environments_ready(joinpath(envs, "transitive"))
        project = _environments_project(environment)
        core = string(_environments_tool("JETLSCore").uuid)
        @test !haskey(project["deps"], "PreferenceDependency")
        @test project["extras"] == Dict("PreferenceDependency" => dependency_uuid, "JETLSCore" => core)
        @test _environments_path(environment, dependency_uuid) == dependency
        @test _environments_preferences(environment)["JETLSCore"] ==
              Dict("JETLS_DEV_MODE" => true, "kept" => "yes")
        @test _environments_run(environment, """
            print(Base.get_preferences(Base.UUID("$dependency_uuid"))["mode"], ' ',
                  Base.get_preferences(Base.UUID("$core"))["JETLS_DEV_MODE"])
            """) == "target true"
    end
end

@testset "compat bounds of combined projects intersect" begin
    _environments_sandbox() do root, envs
        _, helper_uuid = _environments_package(root, "CompatHelper")
        function merged(name, package_bound, test_bound)
            parent, _ = _environments_package(root, name; deps=Dict("CompatHelper" => helper_uuid),
                extras=Dict("CompatExtra" => string(uuid4())),
                compat=Dict("CompatHelper" => package_bound, "CompatExtra" => "1", "julia" => "1.10"),
                sources=Dict("CompatHelper" => Dict("path" => "../CompatHelper")))
            _environments_write(joinpath(parent, "test", "Project.toml"), Dict(
                "deps" => Dict("CompatHelper" => helper_uuid), "compat" => Dict("CompatHelper" => test_bound)))
            context = _environments_context(joinpath(parent, "test"), parent; test=true)
            return _environments_prepare(context, joinpath(envs, name))
        end
        # The package's bound, its test project's bound, and versions inside and outside their intersection.
        cases = (("DisjointParent", "1, 3", "1, 3", [v"1.0.0", v"3.0.0"], [v"2.0.0"]),
                 ("NarrowedParent", "1, 3", "2 - 3", [v"3.5.0"], [v"1.0.0", v"2.5.0"]),
                 ("PinnedParent", "1", "=1.2.3", [v"1.2.3"], [v"1.2.4"]),
                 ("TildeParent", "~1.2", "~1.2", [v"1.2.9"], [v"1.3.0"]),
                 ("UnboundedParent", ">= 1.2", ">= 1.5", [v"1.5.0", v"3.0.0"], [v"1.4.0"]))
        for (name, package_bound, test_bound, inside, outside) in cases
            environment = merged(name, package_bound, test_bound)
            @test environment == _environments_ready(joinpath(envs, name))
            JETSweep.ready(environment) || continue
            compat = Pkg.Types.read_project(joinpath(environment.dir, "Project.toml")).compat
            @test keys(compat) == Set(["CompatHelper", "julia"])
            @test filter(in(compat["CompatHelper"].val), [inside; outside]) == inside
        end

        incompatible = merged("IncompatibleParent", "1", "2")
        @test incompatible.status === :failed
        @test occursin("incompatible compat bounds for CompatHelper: 1 and 2", incompatible.message)
    end
end

@testset "compat and sources on names JETLS vendors privately stay with the target" begin
    _environments_sandbox() do root, envs
        preferences_uuid = "21216c6a-2e73-6563-6e65-726566657250"   # registered; JETLS vendors its own
        locked = Pkg.Types.EnvCache(JETSweep.tool_project()).manifest[UUID(preferences_uuid)].version
        function target(name, compat; deps=Dict("Preferences" => preferences_uuid), fields...)
            compat = merge(Dict("julia" => "1.10"), compat)
            return first(_environments_package(root, name; body="using Preferences", deps, compat, fields...))
        end
        deferring = target("DeferringParent", Dict("Preferences" => "1"))
        deferred = _environments_prepare(_environments_context(deferring), joinpath(envs, "deferred");
                                         instantiate=true)
        @test deferred == _environments_ready(joinpath(envs, "deferred"))
        @test keys(_environments_project(deferred)["compat"]) == Set(["julia"])
        @test _environments_manifest(deferred)[UUID(preferences_uuid)].version == locked

        violator = target("ViolatingParent", Dict("Preferences" => "2"))
        violating = _environments_prepare(_environments_context(violator), joinpath(envs, "violating"))
        @test violating.status === :failed
        @test occursin("Preferences $locked does not satisfy its compat bound \"2\"", violating.message)

        # A developed JET, older than the analyzer's vendored JET or at its version: the target's bound and
        # path source apply to the developed JET only.
        vendored = _environments_tool("JET")
        for (name, version) in (("OldJETDeveloper", v"0.9.0"), ("CurrentJETDeveloper", vendored.version))
            checkout, jet_uuid = _environments_package(joinpath(root, "checkouts", name), "JET";
                uuid="c3a54625-cd67-489e-a8e7-0a5a0ff4e31b", version=string(version))
            developer = target(name, Dict("Preferences" => "1", "JET" => "=$version");
                deps=Dict("Preferences" => preferences_uuid, "JET" => jet_uuid),
                sources=Dict("JET" => Dict("path" => "../checkouts/$name/JET")))
            developed = _environments_prepare(_environments_context(developer), joinpath(envs, name);
                                              instantiate=true)
            @test developed == _environments_ready(joinpath(envs, name))
            JETSweep.ready(developed) || continue
            manifest = _environments_manifest(developed)
            developed_jet, analyzer_jet = manifest[UUID(jet_uuid)], manifest[vendored.uuid]
            @test (developed_jet.version, _environments_path(developed, jet_uuid)) == (version, checkout)
            @test (analyzer_jet.path, analyzer_jet.tree_hash) == (nothing, vendored.tree_hash)
            @test _environments_run(developed, "using $name, JET; print(JET.value())") == "42"
        end
    end
end

@testset "preparation never runs dependency build scripts, including the re-resolve fallback" begin
    _environments_sandbox() do root, envs
        dependency_uuid = string(uuid4())
        dependency, _ = _environments_package(root, "BuildGuardDependency"; uuid=dependency_uuid,
                                              body="value() = 1")
        marker = joinpath(root, "build-script-ran.marker")
        write(joinpath(mkpath(joinpath(dependency, "deps")), "build.jl"),
              "write($(repr(marker)), \"build script executed\")\n")
        repository = LibGit2.init(dependency)
        try
            _environments_commit(repository, "Version one")
            parent, _ = _environments_package(root, "BuildGuardParent";
                deps=Dict("BuildGuardDependency" => dependency_uuid), compat=Dict("BuildGuardDependency" => "1"),
                sources=Dict("BuildGuardDependency" =>
                             Dict("url" => dependency, "rev" => LibGit2.headname(repository))))
            context = _environments_context(parent)
            code = "using BuildGuardParent, BuildGuardDependency; print(BuildGuardDependency.value())"
            before = _environments_snapshot(parent)
            normal = _environments_prepare(context, joinpath(envs, "normal"); instantiate=true)
            @test normal == _environments_ready(joinpath(envs, "normal"))
            @test !ispath(marker)
            @test _environments_snapshot(parent) == before
            JETSweep.ready(normal) || return
            @test _environments_run(normal, code) == "1"

            # Lock v1 exactly, advance the same branch to v2, then require v2: the exact resolution fails,
            # so preparation takes its re-resolve fallback and installs the new source tree.
            seed = _environments_manifest(normal)
            for entry in values(seed)
                entry.path === nothing || (entry.path = abspath(normal.dir, entry.path))
            end
            Pkg.Types.write_manifest(seed, joinpath(parent, "Manifest.toml"))
            project_file = joinpath(dependency, "Project.toml")
            _environments_write(project_file, merge(TOML.parsefile(project_file), Dict("version" => "2.0.0")))
            write(joinpath(dependency, "src", "BuildGuardDependency.jl"),
                  "module BuildGuardDependency\nvalue() = 2\nend\n")
            _environments_commit(repository, "Version two")
            project = TOML.parsefile(joinpath(parent, "Project.toml"))
            project["compat"]["BuildGuardDependency"] = "2"
            _environments_write(joinpath(parent, "Project.toml"), project)
            before = _environments_snapshot(parent)
            fallback = _environments_prepare(context, joinpath(envs, "fallback"); instantiate=true)
            @test fallback.status === :ready
            @test occursin("re-resolved: BuildGuardDependency 1.0.0 → 2.0.0", fallback.message)
            @test !ispath(marker)
            @test _environments_snapshot(parent) == before
            JETSweep.ready(fallback) || return
            @test _environments_run(fallback, code) == "2"
            manifest_file = joinpath(fallback.dir, "Manifest.toml")
            entry = Pkg.Types.read_manifest(manifest_file)[UUID(dependency_uuid)]
            @test entry.version == v"2.0.0"
            # Positive control: the installed build script really would have written the marker.
            installed = Pkg.Operations.source_path(manifest_file, entry)
            Base.include(Module(:BuildGuardControl), joinpath(installed, "deps", "build.jl"))
            @test read(marker, String) == "build script executed"
        finally
            close(repository)
        end
    end
end
