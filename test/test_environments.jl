using Pkg, TOML, SHA, UUIDs, LibGit2

function _envtest_package(root, name; uuid=string(uuid4()), extra=Dict{String,Any}(), body="value() = 42")
    directory = joinpath(root, name)
    mkpath(joinpath(directory, "src"))
    project = merge(Dict{String,Any}("name" => name, "uuid" => uuid, "version" => "1.0.0"), extra)
    open(io -> TOML.print(io, project; sorted=true), joinpath(directory, "Project.toml"), "w")
    write(joinpath(directory, "src", "$name.jl"), "module $name\n$body\nend\n")
    return directory, uuid
end

_envtest_job(path; kind=:package, project=path, entry=joinpath(path, "src", "$(basename(path)).jl"), triggers=Dict{String,String}()) =
    JETSweep.AnalysisJob(id="fixture", kind=kind, entry=entry, project=project, owner=path, triggers=triggers)

function _envtest_load(result, expression)
    separator = Sys.iswindows() ? ';' : ':'
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(result.project) -e $expression`
    return read(addenv(command, "JULIA_LOAD_PATH" => join(result.load_paths, separator)), String)
end

@testset "URL sources resolve in scratch and preserve exact commits" begin
    mktempdir() do root
        repository = joinpath(root, "UrlRepository")
        trigger, trigger_uuid = _envtest_package(repository, "UrlTrigger")
        repo = LibGit2.init(repository)
        signature = LibGit2.Signature("JETSweep fixture", "fixture@example.invalid")
        revision = try
            LibGit2.add!(repo, "*")
            string(LibGit2.commit(repo, "Fixture"; author=signature, committer=signature))
        finally
            close(repo)
        end
        parent, _ = _envtest_package(root, "UrlParent"; extra=Dict(
            "deps" => Dict("UrlTrigger" => trigger_uuid),
            "sources" => Dict("UrlTrigger" => Dict("url" => "../UrlRepository", "rev" => revision, "subdir" => "UrlTrigger"))))
        original = read(joinpath(parent, "Project.toml"))
        job = _envtest_job(parent)
        active_project, load_path = Base.active_project(), copy(LOAD_PATH)
        result = JETSweep.prepare_environment(job, joinpath(root, "url_environment"))
        @test result.status === :ready
        if result.status === :ready
            prepared = Pkg.Types.EnvCache(joinpath(result.project, "Project.toml"))
            @test prepared.manifest[UUID(trigger_uuid)].repo.rev == revision
            @test prepared.manifest[UUID(trigger_uuid)].repo.subdir == "UrlTrigger"
            @test _envtest_load(result, "using UrlParent, UrlTrigger; print(UrlTrigger.value())") == "42"
        else
            @error result.message
        end
        @test read(joinpath(parent, "Project.toml")) == original
        @test !isfile(joinpath(parent, "Manifest.toml"))
        @test Base.active_project() == active_project
        @test LOAD_PATH == load_path
    end
end

@testset "isolated environment preparation" begin
    mktempdir() do root
        parent, parent_uuid = _envtest_package(root, "EnvironmentParent")
        project_file = joinpath(parent, "Project.toml")
        original = read(project_file)
        job = _envtest_job(parent)
        result = JETSweep.prepare_environment(job, joinpath(root, "prepared"); instantiate=false)
        @test result.status === :ready
        @test result.load_paths == [result.project, "@stdlib"]
        @test read(project_file) == original
        @test _envtest_load(result, "using EnvironmentParent; print(EnvironmentParent.value())") == "42"
        @test haskey(result.fingerprints, joinpath(parent, "src", "EnvironmentParent.jl"))
        original_key = JETSweep.environment_key(job)
        same_context = JETSweep.AnalysisJob(id="other", kind=:package, entry="other.jl", project=parent, owner=parent)
        @test JETSweep.environment_key(same_context) == original_key
        write(joinpath(parent, "LocalPreferences.toml"), "[EnvironmentParent]\nbackend = \"cpu\"\n")
        @test JETSweep.environment_key(job) != original_key
        result2 = JETSweep.prepare_environment(job, joinpath(root, "with_preferences"); instantiate=false)
        @test TOML.parsefile(joinpath(result2.project, "LocalPreferences.toml"))["EnvironmentParent"]["backend"] == "cpu"
        @test JETSweep.prepare_environment(job, result.project; instantiate=false).status === :failed
    end
end

@testset "test targets and dedicated projects" begin
    mktempdir() do root
        helper, helper_uuid = _envtest_package(root, "ExtraHelper")
        test_helper, test_uuid = _envtest_package(root, "TestProjectHelper")
        parent, _ = _envtest_package(root, "TestParent"; extra=Dict(
            "extras" => Dict("ExtraHelper" => helper_uuid, "Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40"),
            "targets" => Dict("test" => ["ExtraHelper", "Test"]),
            "sources" => Dict("ExtraHelper" => Dict("path" => "../ExtraHelper"))))
        mkpath(joinpath(parent, "test"))
        parent_uuid = TOML.parsefile(joinpath(parent, "Project.toml"))["uuid"]
        test_project = Dict("deps" => Dict("TestProjectHelper" => test_uuid, "TestParent" => parent_uuid),
            "sources" => Dict("TestProjectHelper" => Dict("path" => "../../TestProjectHelper"),
                "TestParent" => Dict("path" => "..")))
        open(io -> TOML.print(io, test_project), joinpath(parent, "test", "Project.toml"), "w")
        originals = Dict(file => read(file) for file in
            [joinpath(parent, "Project.toml"), joinpath(parent, "test", "Project.toml"), joinpath(helper, "Project.toml")])
        test_job = _envtest_job(parent; kind=:test, project=joinpath(parent, "test"), entry=joinpath(parent, "test", "runtests.jl"))
        result = JETSweep.prepare_environment(test_job, joinpath(root, "test_environment"))
        @test result.status === :ready
        if result.status === :ready
            deps = TOML.parsefile(joinpath(result.project, "Project.toml"))["deps"]
            @test all(name -> haskey(deps, name), ["TestParent", "ExtraHelper", "TestProjectHelper", "Test"])
            @test _envtest_load(result, "using TestParent, ExtraHelper, TestProjectHelper, Test; print(ExtraHelper.value() + TestProjectHelper.value())") == "84"
        else
            @error result.message
        end
        @test all(file -> read(file) == originals[file], keys(originals))
        @test !isfile(joinpath(parent, "Manifest.toml"))
        package_result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "package_environment"); instantiate=false)
        @test package_result.status === :ready
        @test !haskey(TOML.parsefile(joinpath(package_result.project, "Project.toml"))["deps"], "ExtraHelper")
        @test JETSweep.environment_key(test_job) != JETSweep.environment_key(_envtest_job(parent))
    end
end

@testset "multiple extension triggers and source UUIDs" begin
    mktempdir() do root
        first_trigger, first_uuid = _envtest_package(root, "FirstTrigger")
        second_trigger, second_uuid = _envtest_package(root, "SecondTrigger")
        parent, _ = _envtest_package(root, "ExtensionParent"; extra=Dict(
            "weakdeps" => Dict("FirstTrigger" => first_uuid, "SecondTrigger" => second_uuid),
            "extras" => Dict("FirstTrigger" => first_uuid, "SecondTrigger" => second_uuid),
            "extensions" => Dict("BothExt" => ["FirstTrigger", "SecondTrigger"]),
            "sources" => Dict("FirstTrigger" => Dict("path" => "../FirstTrigger"),
                "SecondTrigger" => Dict("path" => "../SecondTrigger"))))
        mkpath(joinpath(parent, "ext"))
        write(joinpath(parent, "ext", "BothExt.jl"), "module BothExt\nusing ExtensionParent, FirstTrigger, SecondTrigger\nvalue() = 84\nend\n")
        triggers = Dict("FirstTrigger" => first_uuid, "SecondTrigger" => second_uuid)
        job = _envtest_job(parent; kind=:extension, triggers=triggers)
        result = JETSweep.prepare_environment(job, joinpath(root, "extensions"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            @test _envtest_load(result, "using ExtensionParent, FirstTrigger, SecondTrigger; print(Base.get_extension(ExtensionParent, :BothExt).value())") == "84"
        end
        old_key = JETSweep.environment_key(job)
        write(joinpath(first_trigger, "src", "FirstTrigger.jl"), "module FirstTrigger\nvalue() = 43\nend\n")
        @test JETSweep.environment_key(job) != old_key
        bad = _envtest_job(parent; kind=:extension, triggers=Dict("FirstTrigger" => string(uuid4())))
        failure = JETSweep.prepare_environment(bad, joinpath(root, "wrong_uuid"); instantiate=false)
        @test failure.status === :failed
        @test occursin("UUID mismatch", failure.message)
    end
end

@testset "nearest script project and unavailable dependencies" begin
    mktempdir() do root
        parent, _ = _envtest_package(root, "ScriptParent")
        scripts = joinpath(parent, "scripts")
        mkpath(scripts)
        write(joinpath(scripts, "Project.toml"), "[deps]\n")
        job = _envtest_job(parent; kind=:script, project=scripts, entry=joinpath(scripts, "run.jl"))
        result = JETSweep.prepare_environment(job, joinpath(root, "script_environment"); instantiate=false)
        @test result.status === :ready
        @test isempty(TOML.parsefile(joinpath(result.project, "Project.toml"))["deps"])
        source_job = _envtest_job(parent; kind=:source, project=scripts, entry=joinpath(scripts, "owned.jl"))
        source_result = JETSweep.prepare_environment(source_job, joinpath(root, "owned_source_environment"); instantiate=false)
        @test source_result.status === :ready
        @test haskey(TOML.parsefile(joinpath(source_result.project, "Project.toml"))["deps"], "ScriptParent")
        @test JETSweep.environment_key(source_job) != JETSweep.environment_key(job)
        missing_uuid = string(uuid4())
        write(joinpath(scripts, "Project.toml"), "[deps]\nUnregisteredSibling = \"$missing_uuid\"\n")
        _envtest_package(root, "UnregisteredSibling"; uuid=missing_uuid)
        missing = JETSweep.prepare_environment(job, joinpath(root, "missing"); instantiate=false)
        @test missing.status === :failed
        @test occursin("UnregisteredSibling", missing.message)
        @test occursin("instantiate=false", missing.message)
    end
end

@testset "native workspaces and active versioned manifests" begin
    mktempdir() do root
        member, member_uuid = _envtest_package(root, "WorkspaceMember")
        parent, _ = _envtest_package(root, "WorkspaceParent"; extra=Dict(
            "deps" => Dict("WorkspaceMember" => member_uuid)))
        root_project = Dict("workspace" => Dict("projects" => ["WorkspaceParent", "WorkspaceMember"]),
            "preferences" => Dict("WorkspaceParent" => Dict("backend" => "workspace")))
        open(io -> TOML.print(io, root_project), joinpath(root, "Project.toml"), "w")
        originals = Dict(file => read(file) for file in
            [joinpath(root, "Project.toml"), joinpath(parent, "Project.toml"), joinpath(member, "Project.toml")])
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "workspace_environment"))
        @test result.status === :ready
        if result.status === :ready
            @test _envtest_load(result, "using WorkspaceParent, WorkspaceMember; print(WorkspaceMember.value())") == "42"
            @test TOML.parsefile(joinpath(result.project, "LocalPreferences.toml"))["WorkspaceParent"]["backend"] == "workspace"
        else
            @error result.message
        end
        @test all(file -> read(file) == originals[file], keys(originals))
        @test !isfile(joinpath(root, "Manifest.toml"))
        # Only Julia's active version-specific filename may seed preparation.
        manifest = Pkg.Types.Manifest(julia_version=VERSION, manifest_format=v"2.0")
        manifest[UUID(member_uuid)] = Pkg.Types.PackageEntry(name="WorkspaceMember", uuid=UUID(member_uuid),
            version=v"1.0.0", path="WorkspaceMember")
        active_manifest = joinpath(root, "JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml")
        Pkg.Types.write_manifest(manifest, active_manifest)
        write(joinpath(root, "Manifest.toml"), "invalid = [\n")
        prepared = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "versioned"); instantiate=false)
        @test prepared.status === :ready
        @test haskey(prepared.fingerprints, active_manifest)
        @test !haskey(prepared.fingerprints, joinpath(root, "Manifest.toml"))
    end
end

@testset "stale path manifest metadata is refreshed" begin
    mktempdir() do root
        helper, helper_uuid = _envtest_package(root, "FreshHelper")
        parent, parent_uuid = _envtest_package(root, "StaleParent"; extra=Dict(
            "deps" => Dict("FreshHelper" => helper_uuid),
            "sources" => Dict("FreshHelper" => Dict("path" => "../FreshHelper"))))
        manifest = Pkg.Types.Manifest(julia_version=VERSION, manifest_format=v"2.0")
        manifest[UUID(parent_uuid)] = Pkg.Types.PackageEntry(name="StaleParent", uuid=UUID(parent_uuid),
            path=".", version=v"0.1.0")
        Pkg.Types.write_manifest(manifest, joinpath(parent, "Manifest.toml"))
        original = read(joinpath(parent, "Manifest.toml"))
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "refreshed"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            prepared = Pkg.Types.EnvCache(joinpath(result.project, "Project.toml"))
            @test prepared.manifest[UUID(parent_uuid)].deps["FreshHelper"] == UUID(helper_uuid)
            @test prepared.manifest[UUID(parent_uuid)].version == v"1.0.0"
            @test prepared.manifest[UUID(helper_uuid)].path == helper
        end
        @test read(joinpath(parent, "Manifest.toml")) == original
    end
end

@testset "explicit sources override stale manifest locations" begin
    mktempdir() do root
        helper, helper_uuid = _envtest_package(root, "ChosenHelper")
        parent, _ = _envtest_package(root, "SourceParent"; extra=Dict(
            "deps" => Dict("ChosenHelper" => helper_uuid),
            "sources" => Dict("ChosenHelper" => Dict("path" => "../ChosenHelper"))))
        manifest = Pkg.Types.Manifest(julia_version=VERSION, manifest_format=v"2.0")
        manifest[UUID(helper_uuid)] = Pkg.Types.PackageEntry(name="ChosenHelper", uuid=UUID(helper_uuid),
            path="../obsolete-checkout", version=v"1.0.0")
        orphan_uuid = uuid4()
        manifest[orphan_uuid] = Pkg.Types.PackageEntry(name="UnusedOldPackage", uuid=orphan_uuid,
            path="../missing-orphan", version=v"1.0.0")
        Pkg.Types.write_manifest(manifest, joinpath(parent, "Manifest.toml"))
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "source_override"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            prepared = Pkg.Types.EnvCache(joinpath(result.project, "Project.toml"))
            @test prepared.manifest[UUID(helper_uuid)].path == helper
            @test !haskey(prepared.manifest, orphan_uuid)
            @test _envtest_load(result, "using ChosenHelper; print(ChosenHelper.value())") == "42"
        else
            @error result.message
        end
    end
end

@testset "offline standard library dependency closure" begin
    mktempdir() do root
        parent, _ = _envtest_package(root, "StdlibParent"; extra=Dict(
            "deps" => Dict("Random" => "9a3f8284-a2c9-5f02-9a11-845980a1fd5c")),
            body="using Random\nvalue() = rand(MersenneTwister(123), 1:1)")
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "stdlib"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            @test _envtest_load(result, "using StdlibParent; print(StdlibParent.value())") == "1"
            @test haskey(Pkg.Types.EnvCache(joinpath(result.project, "Project.toml")).manifest,
                UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c"))
        else
            @error result.message
        end
    end
end

@testset "native preference precedence and clear semantics" begin
    mktempdir() do root
        parent, _ = _envtest_package(root, "PreferenceParent"; extra=Dict(
            "preferences" => Dict("PreferenceParent" => Dict("backend" => "exported", "clear_me" => true))))
        write(joinpath(parent, "LocalPreferences.toml"), "[PreferenceParent]\nbackend = \"local\"\nignored = true\n")
        write(joinpath(parent, "JuliaLocalPreferences.toml"),
            "[PreferenceParent]\nbackend = \"julia-local\"\n__clear__ = [\"clear_me\"]\n")
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "preferences"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            prefs = TOML.parsefile(joinpath(result.project, "LocalPreferences.toml"))["PreferenceParent"]
            @test prefs["backend"] == "julia-local"
            @test !haskey(prefs, "clear_me")
            @test !haskey(prefs, "ignored")
        end
    end
end

@testset "disjoint compatibility ranges survive context merging" begin
    mktempdir() do root
        helper, helper_uuid = _envtest_package(root, "CompatHelper")
        parent, _ = _envtest_package(root, "CompatParent"; extra=Dict(
            "deps" => Dict("CompatHelper" => helper_uuid), "compat" => Dict("CompatHelper" => "1, 3"),
            "sources" => Dict("CompatHelper" => Dict("path" => "../CompatHelper"))))
        mkpath(joinpath(parent, "test"))
        project = Dict("deps" => Dict("CompatHelper" => helper_uuid), "compat" => Dict("CompatHelper" => "1, 3"))
        open(io -> TOML.print(io, project), joinpath(parent, "test", "Project.toml"), "w")
        result = JETSweep.prepare_environment(_envtest_job(parent; kind=:test), joinpath(root, "compat"))
        @test result.status === :ready
        if result.status === :ready
            compat = Pkg.Types.EnvCache(joinpath(result.project, "Project.toml")).project.compat["CompatHelper"].val
            @test v"1.0.0" in compat
            @test v"3.0.0" in compat
            @test !(v"2.0.0" in compat)
        else
            @error result.message
        end
    end
end

@testset "resolution and fallback never run dependency build scripts" begin
    mktempdir() do root
        dependency_uuid = string(uuid4())
        dependency, _ = _envtest_package(root, "BuildGuardDependency"; uuid=dependency_uuid, body="value() = 1")
        parent, _ = _envtest_package(root, "BuildGuardParent"; extra=Dict(
            "deps" => Dict("BuildGuardDependency" => dependency_uuid),
            "compat" => Dict("BuildGuardDependency" => "1")))
        marker = joinpath(parent, "src", "build-script-ran.marker")
        mkpath(joinpath(dependency, "deps"))
        write(joinpath(dependency, "deps", "build.jl"), "write($(repr(marker)), \"build script executed\")\n")
        repository = LibGit2.init(dependency)
        signature = LibGit2.Signature("JETSweep build fixture", "fixture@example.invalid")
        try
            LibGit2.add!(repository, "*")
            LibGit2.commit(repository, "Version one"; author=signature, committer=signature)
            branch = LibGit2.headname(repository)
            parent_file = joinpath(parent, "Project.toml")
            project = TOML.parsefile(parent_file)
            project["sources"] = Dict("BuildGuardDependency" => Dict("url" => dependency, "rev" => branch))
            open(io -> TOML.print(io, project; sorted=true), parent_file, "w")
            original_project = read(parent_file)
            normal = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "normal"))
            @test normal.status === :ready
            @test isempty(normal.message)
            @test !isfile(marker)
            @test read(parent_file) == original_project
            @test !isfile(joinpath(parent, "Manifest.toml"))
            normal.status === :ready || error(normal.message)
            @test _envtest_load(normal, "using BuildGuardParent, BuildGuardDependency; print(BuildGuardDependency.value())") == "1"

            # Preserve an exact v1 manifest, advance the same Git branch to v2,
            # then require v2. Fixed-level resolution must fail, so preparation
            # exercises its real fallback path and downloads the new source tree.
            seed = Pkg.Types.read_manifest(joinpath(normal.project, "Manifest.toml"))
            for entry in values(seed)
                entry.path === nothing || (entry.path = abspath(normal.project, entry.path))
            end
            Pkg.Types.write_manifest(seed, joinpath(parent, "Manifest.toml"))
            dependency_file = joinpath(dependency, "Project.toml")
            dependency_project = TOML.parsefile(dependency_file)
            dependency_project["version"] = "2.0.0"
            open(io -> TOML.print(io, dependency_project; sorted=true), dependency_file, "w")
            write(joinpath(dependency, "src", "BuildGuardDependency.jl"), "module BuildGuardDependency\nvalue() = 2\nend\n")
            LibGit2.add!(repository, "*")
            LibGit2.commit(repository, "Version two"; author=signature, committer=signature)
            project["compat"]["BuildGuardDependency"] = "2"
            open(io -> TOML.print(io, project; sorted=true), parent_file, "w")
            original_project = read(parent_file)
            original_manifest = read(joinpath(parent, "Manifest.toml"))
            fallback = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "fallback"))
            @test fallback.status === :ready
            @test occursin("re-resolved", fallback.message)
            @test !isfile(marker)
            @test read(parent_file) == original_project
            @test read(joinpath(parent, "Manifest.toml")) == original_manifest
            fallback.status === :ready || error(fallback.message)
            @test _envtest_load(fallback, "using BuildGuardParent, BuildGuardDependency; print(BuildGuardDependency.value())") == "2"
            env = Pkg.Types.EnvCache(joinpath(fallback.project, "Project.toml"))
            @test env.manifest[UUID(dependency_uuid)].version == v"2.0.0"
            installed = Pkg.Operations.source_path(env.manifest_file, env.manifest[UUID(dependency_uuid)])
            @test isfile(joinpath(installed, "deps", "build.jl"))
            # Positive control after all preparation/immutability assertions:
            # the installed sentinel really would mutate the original target.
            Base.include(Module(:BuildSentinelControl), joinpath(installed, "deps", "build.jl"))
            @test read(marker, String) == "build script executed"
        finally
            close(repository)
        end
    end
end

@testset "preferences retain optional transitive UUID bindings" begin
    mktempdir() do root
        dependency, dependency_uuid = _envtest_package(root, "PreferenceDependency")
        helper, helper_uuid = _envtest_package(root, "PreferenceHelper"; extra=Dict(
            "deps" => Dict("PreferenceDependency" => dependency_uuid),
            "sources" => Dict("PreferenceDependency" => Dict("path" => "../PreferenceDependency"))))
        parent, _ = _envtest_package(root, "OptionalPreferenceParent"; extra=Dict(
            "deps" => Dict("PreferenceHelper" => helper_uuid),
            "extras" => Dict("PreferenceDependency" => dependency_uuid),
            "sources" => Dict("PreferenceHelper" => Dict("path" => "../PreferenceHelper"))))
        write(joinpath(parent, "LocalPreferences.toml"), "[PreferenceDependency]\nmode = \"target\"\n")
        result = JETSweep.prepare_environment(_envtest_job(parent), joinpath(root, "prepared"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            project = TOML.parsefile(joinpath(result.project, "Project.toml"))
            @test !haskey(project["deps"], "PreferenceDependency")
            @test project["extras"]["PreferenceDependency"] == dependency_uuid
            @test _envtest_load(result, "print(Base.get_preferences(Base.UUID(\"$dependency_uuid\"))[\"mode\"])") == "target"
        end
    end
end
