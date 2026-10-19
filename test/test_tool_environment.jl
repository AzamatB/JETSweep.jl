using Test, Pkg, TOML, UUIDs

function _tooltest_target(directory; name="ToolFixture", uuid=string(uuid4()), version="1.0.0")
    mkpath(joinpath(directory, "src"))
    project = Dict("name" => name, "uuid" => uuid, "version" => version)
    open(io -> TOML.print(io, project; sorted=true), joinpath(directory, "Project.toml"), "w")
    write(joinpath(directory, "src", name * ".jl"), "module $name\nend\n")
    job = JETSweep.AnalysisJob(id=name, kind=:package, project=directory, owner=directory,
        entry=joinpath(directory, "src", name * ".jl"))
    return JETSweep.prepare_environment(job, directory * "-prepared"; instantiate=false)
end

@testset "tool environment retains exact target identities" begin
    mktempdir() do root
        target = _tooltest_target(joinpath(root, "ordinary"))
        @test target.status === :ready
        unchanged = JETSweep.prepare_tool_environment(target, joinpath(root, "no-adaptation"); instantiate=false)
        @test unchanged.status === :ready
        @test unchanged.project == target.project
        @test unchanged.load_paths == target.load_paths
        @test unchanged.tool_project == dirname(JETSweep._tool_project())
        @test haskey(unchanged.fingerprints, JETSweep._tool_project())
        @test !isdir(joinpath(root, "no-adaptation"))
        failed = JETSweep.EnvironmentResult(status=:failed, message="Target unavailable")
        @test JETSweep.prepare_tool_environment(failed, joinpath(root, "failed")) === failed
    end
end

@testset "canonical package source aligns without changing private namesakes" begin
    mktempdir() do root
        baseline = Pkg.Types.EnvCache(JETSweep._tool_project())
        uuid = UUID("21216c6a-2e73-6563-6e65-726566657250")
        private_uuid = UUID("cc588e5a-7be0-5224-8a6a-549b21958db9")
        jetls_uuid = UUID("a3b70258-0602-4ee2-b5a6-54c2470400db")
        original_source = Pkg.Operations.source_path(baseline.manifest_file, baseline.manifest[uuid])
        local_source = joinpath(root, "Preferences")
        cp(original_source, local_source)
        job = JETSweep.AnalysisJob(id="local-preferences", kind=:package, project=local_source, owner=local_source,
            entry=joinpath(local_source, "src", "Preferences.jl"))
        target = JETSweep.prepare_environment(job, joinpath(root, "target"); instantiate=false)
        @test target.status === :ready
        original_target_manifest = read(joinpath(target.project, "Manifest.toml"))
        original_tool_manifest = read(baseline.manifest_file)
        result = JETSweep.prepare_tool_environment(target, joinpath(root, "tool"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            prepared = Pkg.Types.EnvCache(joinpath(result.tool_project, "Project.toml"))
            @test realpath(Pkg.Operations.source_path(prepared.manifest_file, prepared.manifest[uuid])) == realpath(local_source)
            @test prepared.manifest[uuid].version == baseline.manifest[uuid].version
            @test prepared.manifest[uuid].pinned
            @test prepared.manifest[private_uuid].tree_hash == baseline.manifest[private_uuid].tree_hash
            @test prepared.manifest[private_uuid].repo == baseline.manifest[private_uuid].repo
            @test prepared.manifest[jetls_uuid].tree_hash == baseline.manifest[jetls_uuid].tree_hash
            @test prepared.manifest[jetls_uuid].repo == baseline.manifest[jetls_uuid].repo
            @test result.project == target.project && result.load_paths == target.load_paths
            @test haskey(result.fingerprints, joinpath(result.tool_project, "Manifest.toml"))
            @test haskey(result.fingerprints, joinpath(local_source, "src", "Preferences.jl"))
        else
            @error result.message
        end
        @test read(joinpath(target.project, "Manifest.toml")) == original_target_manifest
        @test read(baseline.manifest_file) == original_tool_manifest
        # A compatible source checkout is accepted; an incompatible version must
        # fail without relaxing the prepared target or changing upstream bounds.
        project_file = joinpath(local_source, "Project.toml")
        chmod(project_file, 0o644) # Installed package files may be read-only.
        project = TOML.parsefile(project_file)
        project["version"] = "999.0.0"
        open(io -> TOML.print(io, project; sorted=true), project_file, "w")
        incompatible_target = JETSweep.prepare_environment(job, joinpath(root, "incompatible-target"); instantiate=false)
        @test incompatible_target.status === :ready
        rejected = JETSweep.prepare_tool_environment(incompatible_target, joinpath(root, "incompatible-tool"); instantiate=false)
        @test rejected.status === :failed
        @test occursin("incompatible", rejected.message)
        @test occursin("Preferences", rejected.message)
    end
end

@testset "pinned JETLS source cannot be adapted to a target checkout" begin
    mktempdir() do root
        target = _tooltest_target(joinpath(root, "conflicting-release"); name="JETLS",
            uuid="a3b70258-0602-4ee2-b5a6-54c2470400db", version="2026.10.14")
        @test target.status === :ready
        rejected = JETSweep.prepare_tool_environment(target, joinpath(root, "tool"); instantiate=false)
        @test rejected.status === :failed
        @test occursin("fixed tool dependency JETLS", rejected.message)
    end
end

@testset "shared preferences align by UUID without affecting private namesakes" begin
    mktempdir() do root
        baseline = Pkg.Types.EnvCache(JETSweep._tool_project())
        canonical = UUID("21216c6a-2e73-6563-6e65-726566657250")
        private = UUID("cc588e5a-7be0-5224-8a6a-549b21958db9")
        source = Pkg.Operations.source_path(baseline.manifest_file, baseline.manifest[canonical])
        job = JETSweep.AnalysisJob(id="preferences-only", kind=:package, project=source, owner=source,
            entry=joinpath(source, "src", "Preferences.jl"))
        target = JETSweep.prepare_environment(job, joinpath(root, "target"); instantiate=false)
        @test target.status === :ready
        write(joinpath(target.project, "LocalPreferences.toml"), "[Preferences]\njetsweep_fixture_mode = \"target\"\n")
        desired = Pkg.Types.EnvCache(joinpath(target.project, "Project.toml"))
        original_target = read(joinpath(target.project, "LocalPreferences.toml"))
        result = JETSweep.prepare_tool_environment(target, joinpath(root, "tool"); instantiate=false)
        @test result.status === :ready
        if result.status === :ready
            adapted = Pkg.Types.EnvCache(joinpath(result.tool_project, "Project.toml"))
            @test result.tool_project != dirname(JETSweep._tool_project())
            @test JETSweep._tool_matches_target(adapted, adapted.manifest[canonical], desired, desired.manifest[canonical])
            @test JETSweep._tool_effective_preferences(adapted, canonical)["jetsweep_fixture_mode"] == "target"
            @test JETSweep._tool_effective_preferences(adapted, private) == JETSweep._tool_effective_preferences(baseline, private)
            @test adapted.project.extras["Preferences"] == canonical
            @test haskey(result.fingerprints, joinpath(result.tool_project, "LocalPreferences.toml"))
            @test !haskey(adapted.project.deps, "Preferences")
        else
            @error result.message
        end
        @test read(joinpath(target.project, "LocalPreferences.toml")) == original_target
    end
end

@testset "ambiguous shared preference tables fail explicitly" begin
    mktempdir() do root
        manifest = Pkg.Types.EnvCache(JETSweep._tool_project()).manifest
        canonical = "21216c6a-2e73-6563-6e65-726566657250"
        private = "cc588e5a-7be0-5224-8a6a-549b21958db9"
        baseline_directory = joinpath(root, "baseline")
        target_directory = joinpath(root, "target")
        for (directory, uuid, value) in ((baseline_directory, private, "tool"), (target_directory, canonical, "target"))
            mkpath(directory)
            open(io -> TOML.print(io, Dict("extras" => Dict("Preferences" => uuid),
                "preferences" => Dict("Preferences" => Dict("mode" => value)))), joinpath(directory, "Project.toml"), "w")
        end
        baseline = Pkg.Types.EnvCache(joinpath(baseline_directory, "Project.toml"))
        target = Pkg.Types.EnvCache(joinpath(target_directory, "Project.toml"))
        target.manifest[UUID(canonical)] = deepcopy(manifest[UUID(canonical)])
        @test_throws ErrorException JETSweep._tool_preferences(baseline, target, manifest)
        @test JETSweep._tool_effective_preferences(baseline, UUID(private))["mode"] == "tool"
        @test JETSweep._tool_effective_preferences(target, UUID(canonical))["mode"] == "target"
    end
end
