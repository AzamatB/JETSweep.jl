using Test
using TOML
using JETSweep

# Run every analysis in its own process: package/extension loading and JETLS's
# virtual modules must never contaminate another control's analysis context.
function backend_fixture_job(directory, fixtures, name, kind, entry;
        owner="", project="", expected=[entry], extension="", test_entry="", issues=String[],
        containing_files=String[], setup=String[], arguments=String[], variables=Dict{String,String}(),
        blocking_issues=String[], environment_project="")
    config = joinpath(directory,name)
    mkpath(config)
    write(joinpath(config,".JETLSConfig.toml"), """
        [full_analysis]
        auto_instantiate = "never"
        concretization_timeout = 30.0
        [diagnostic]
        enabled = true
        all_files = true
        patterns = []
        [initialization_options]
        reuse_native_inference = false
        """)
    context = JETSweep.ContextSpec(;test_entry,containing_files,setup,arguments,variables)
    triggers = isempty(extension) ? Dict{String,String}() :
        Dict("Test"=>"8dfed614-e22c-5e08-85e1-65c5234f0b40")
    job = JETSweep.AnalysisJob(; id=name,kind,entry,project,owner,expected_files=expected,
        extension,triggers,context,issues,blocking_issues)
    environment = isempty(environment_project) ? joinpath(directory,"environment") : environment_project
    mkpath(environment)
    isempty(environment_project) && write(joinpath(environment,"Project.toml"),"[deps]\n")
    input = joinpath(config,"job.toml")
    output = joinpath(config,"result.toml")
    open(input,"w") do io
        TOML.print(io,Dict("schema_version"=>1,"root"=>fixtures,
            "config_directory"=>config,"environment_project"=>environment,
            "load_paths"=>[environment,fixtures],"job"=>JETSweep.job_dict(job)))
    end
    script = joinpath(pkgdir(JETSweep),"scripts","analyze.jl")
    log = joinpath(config,"worker.log")
    command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --threads=2 --project=$(pkgdir(JETSweep)) $script $input $output`
    command = addenv(command,"JULIA_LOAD_PATH"=>"@:@stdlib","JULIA_PKG_PRECOMPILE_AUTO"=>"0")
    open(log,"w") do io
        process = run(pipeline(command;stdout=io,stderr=io);wait=false)
        if timedwait(() -> process_exited(process),300.0) === :timed_out
            kill(process)
            wait(process)
            error("Backend fixture timed out: $name; log: $log")
        end
        wait(process)
    end
    isfile(output) || error("Backend fixture emitted no structured result: $name\n$(read(log,String))")
    result = TOML.parsefile(output)
    if haskey(result,"error")
        @info "Backend fixture error" name error=result["error"] log
    end
    if get(result,"full_analysis_complete",false)
        @test isempty(result["internal_errors"])
        @test result["jetls_dev_mode"]
        @test haskey(result["source_hashes_before"],joinpath(config,"backend-preferences","Project.toml"))
        @test haskey(result["source_hashes_before"],joinpath(config,"backend-preferences","Manifest.toml"))
        @test !occursin("world prior to its definition",read(log,String))
    end
    return result
end

@testset "isolated JETLS semantic controls" begin
    mktempdir() do directory
        fixtures = joinpath(directory,"fixtures")
        cp(joinpath(@__DIR__,"fixtures","backend"),fixtures)
        package = joinpath(fixtures,"BackendWitness")
        source = joinpath(package,"src","BackendWitness.jl")
        nested = joinpath(package,"src","nested.jl")
        project = joinpath(package,"Project.toml")
        methods_in(result,file) = any(row -> row["file"] == file &&
            startswith(row["code"],"inference/method-error"),result["diagnostics"])

        @testset "recursive package" begin
            result = backend_fixture_job(directory,fixtures,"package",:package,source;
                owner=package,project,expected=[source,nested])
            @test result["status"] == "findings"
            @test result["full_analysis_complete"]
            @test methods_in(result,source)
            @test methods_in(result,nested)
            @test !isempty(result["signatures"])
            @test all(row -> row["analysis_verified"],result["signatures"])
            @test result["parent_identity"]["uuid"] == "4b656040-21d6-4560-9bd0-3816743acc86"
        end
        @testset "recursive abstract script" begin
            entry = joinpath(fixtures,"scripts","failing.jl")
            helper = joinpath(fixtures,"scripts","nested.jl")
            result = backend_fixture_job(directory,fixtures,"script",:script,entry;expected=[entry,helper])
            @test result["status"] == "findings"
            @test result["full_analysis_complete"]
            @test result["jetls_include_traversal_complete"]
            @test methods_in(result,entry)
            @test methods_in(result,helper)
            @test all(row -> startswith(row["uri"],"file:"),result["diagnostics"])
        end
        @testset "disconnected original package source" begin
            entry = joinpath(package,"src","disconnected.jl")
            result = backend_fixture_job(directory,fixtures,"source",:source,entry;owner=package,project)
            @test result["status"] == "findings"
            @test result["full_analysis_complete"]
            @test methods_in(result,entry)
            @test result["context_mode"] == "disconnected_package_source"
            @test !result["original_inclusion_context_reconstructed"]
            @test result["parent_identity"]["source"] == source
        end
        @testset "automatic original test helper context" begin
            entry = joinpath(package,"test","test_case.jl")
            test_entry = joinpath(package,"test","runtests.jl")
            result = backend_fixture_job(directory,fixtures,"test",:test,entry;
                owner=package,project,test_entry)
            @test result["status"] == "findings"
            @test result["full_analysis_complete"]
            @test methods_in(result,entry)
            @test !any(row -> occursin("undef-global-var",row["code"]),result["diagnostics"])
            @test test_entry in result["context_sources"]
            @test joinpath(package,"test","test_helpers.jl") in result["context_sources"]
            @test !isempty(result["context_omissions"])
            @test !isfile(joinpath(package,"test","CAMPAIGN_RAN"))
        end
        @testset "loaded recursive extension" begin
            entry = joinpath(package,"ext","BackendWitnessTestExt.jl")
            helper = joinpath(package,"ext","extension_helper.jl")
            result = backend_fixture_job(directory,fixtures,"extension",:extension,entry;
                owner=package,project,extension="BackendWitnessTestExt",expected=[entry,helper])
            @test result["status"] == "findings"
            @test result["full_analysis_complete"]
            @test methods_in(result,entry)
            @test methods_in(result,helper)
            @test result["target_identity"]["source"] == entry
            loaded = filter(row -> row["parent"]["name"] == "BackendWitness",result["loaded_extensions"])
            @test length(loaded) == 1
            @test only(loaded)["triggers"][1]["uuid"] == "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        end
        @testset "real extension load failure fails closed" begin
            broken = joinpath(fixtures,"BackendBroken")
            entry = joinpath(broken,"ext","BackendBrokenTestExt.jl")
            result = backend_fixture_job(directory,fixtures,"broken",:extension,entry;
                owner=broken,project=joinpath(broken,"Project.toml"),extension="BackendBrokenTestExt")
            @test result["status"] == "analysis_incomplete"
            @test !result["full_analysis_complete"]
            @test occursin("did not load",get(result,"error","")) || !isempty(result["internal_errors"])
        end
        @testset "unsupported mapped include fails closed" begin
            entry = joinpath(fixtures,"scripts","unsupported.jl")
            result = backend_fixture_job(directory,fixtures,"unsupported",:script,entry)
            @test result["status"] == "analysis_incomplete"
            @test !result["full_analysis_complete"]
            @test any(row -> row["code"] == "toplevel/unsupported-feature",result["diagnostics"])
        end
        @testset "missing owned source is explicit" begin
            entry = joinpath(fixtures,"scripts","clean.jl")
            missing = joinpath(fixtures,"scripts","not_included.jl")
            write(missing,"unreached(x::Int) = sin(\"unreached\") + x\n")
            result = backend_fixture_job(directory,fixtures,"missing",:script,entry;expected=[entry,missing])
            @test !result["full_analysis_complete"]
            @test missing in result["missing_files"]
        end
        @testset "containing declarations and literal path bindings" begin
            entry = joinpath(fixtures,"scripts","context","child.jl")
            containing = joinpath(fixtures,"scripts","containing.jl")
            result = backend_fixture_job(directory,fixtures,"containing",:script,entry;
                containing_files=[containing])
            @test result["full_analysis_complete"]
            @test methods_in(result,entry)
            @test isempty(result["context_omissions"])
            @test !any(row -> occursin("undef-global-var",row["code"]),result["diagnostics"])
        end
        @testset "configured setup, arguments, and environment" begin
            entry = joinpath(fixtures,"scripts","configured.jl")
            setup = joinpath(fixtures,"scripts","setup.jl")
            result = backend_fixture_job(directory,fixtures,"configured",:script,entry;
                setup=[setup],arguments=["fixture"],variables=Dict("JETSWEEP_FIXTURE"=>"configured"))
            @test result["full_analysis_complete"]
            @test methods_in(result,entry)
            @test setup in result["analyzed_files"]
            @test result["arguments"] == ["fixture"]
        end
        @testset "changed original source fails closed" begin
            entry = joinpath(fixtures,"scripts","mutating.jl")
            original = joinpath(@__DIR__,"fixtures","backend","scripts","mutating.jl")
            original_contents = read(original,String)
            result = backend_fixture_job(directory,fixtures,"mutating",:script,entry;
                variables=Dict("JETSWEEP_MUTATION_TARGET"=>entry))
            @test result["status"] == "source_changed"
            @test !result["full_analysis_complete"]
            @test entry in result["changed_inputs"]
            @test read(original,String) == original_contents
        end
        @testset "clean result is scoped" begin
            entry = joinpath(fixtures,"scripts","clean.jl")
            result = backend_fixture_job(directory,fixtures,"clean",:script,entry)
            @test result["status"] == "clean"
            @test result["full_analysis_complete"]
            @test isempty(result["diagnostics"])
            @test !isempty(result["limitations"])
        end
        @testset "static advisories do not override completed analysis" begin
            entry = joinpath(fixtures,"scripts","advisory.jl")
            note = "eval may introduce source unavailable to static include discovery"
            result = backend_fixture_job(directory,fixtures,"advisory",:script,entry;issues=[note])
            @test result["full_analysis_complete"]
            @test note in result["context_issues"]
        end
        @testset "explicit context blockers prevent completion" begin
            entry = joinpath(fixtures,"scripts","clean.jl")
            blocker = "Required package metadata is unavailable"
            result = backend_fixture_job(directory,fixtures,"blocked",:script,entry;blocking_issues=[blocker])
            @test result["status"] == "analysis_incomplete"
            @test !result["full_analysis_complete"]
            @test blocker in result["blocking_issues"]
        end
        @testset "matching shared tool dependency identity" begin
            environment = joinpath(directory,"matching-dependency")
            mkpath(environment)
            write(joinpath(environment,"Project.toml"),"""
                [deps]
                PrecompileTools = "32931bc0-5014-5544-84d5-53636ff9f6c5"
                [extras]
                JETLSCore = "8d6afe4c-923b-5912-b63d-b990009c9e74"
                [preferences.JETLSCore]
                JETLS_DEV_MODE = true
                """)
            manifest = Base.project_file_manifest_path(Base.active_project())
            data = TOML.parsefile(manifest)
            for entries in values(data["deps"]), item in entries
                haskey(item,"path") && (item["path"] = abspath(dirname(manifest),item["path"]))
            end
            JETSweep.write_toml(joinpath(environment,"Manifest.toml"),data)
            entry = joinpath(fixtures,"scripts","matching_dependency.jl")
            result = backend_fixture_job(directory,fixtures,"matching-dependency",:script,entry;
                environment_project=environment)
            @test result["full_analysis_complete"]
            @test isempty(result["dependency_identity_conflicts"])
            checks = filter(row -> row["name"] == "PrecompileTools",result["dependency_identity_checks"])
            @test length(checks) == 1
            @test only(checks)["matches"]
        end
        @testset "same UUID with different version and source fails closed" begin
            fake = joinpath(directory,"FakePrecompileTools")
            mkpath(joinpath(fake,"src"))
            write(joinpath(fake,"Project.toml"),"name = \"PrecompileTools\"\nuuid = \"32931bc0-5014-5544-84d5-53636ff9f6c5\"\nversion = \"999.0.0\"\n")
            write(joinpath(fake,"src","PrecompileTools.jl"),"module PrecompileTools\nend\n")
            environment = joinpath(directory,"conflicting-dependency")
            mkpath(environment)
            write(joinpath(environment,"Project.toml"),"[deps]\nPrecompileTools = \"32931bc0-5014-5544-84d5-53636ff9f6c5\"\n")
            JETSweep.write_toml(joinpath(environment,"Manifest.toml"),Dict("manifest_format"=>"2.0",
                "julia_version"=>string(VERSION),"deps"=>Dict("PrecompileTools"=>[
                    Dict("uuid"=>"32931bc0-5014-5544-84d5-53636ff9f6c5","version"=>"999.0.0","path"=>fake)])))
            entry = joinpath(fixtures,"scripts","matching_dependency.jl")
            result = backend_fixture_job(directory,fixtures,"conflicting-dependency",:script,entry;
                environment_project=environment)
            @test result["status"] == "analysis_incomplete"
            @test !result["full_analysis_complete"]
            conflict = only(result["dependency_identity_conflicts"])
            @test conflict["name"] == "PrecompileTools"
            @test conflict["expected_version"] == "999.0.0"
            @test conflict["expected_source"] == fake
            @test conflict["actual_source"] != fake
        end
        @testset "undeclared tool dependency cannot leak into scripts" begin
            entry = joinpath(fixtures,"scripts","undeclared_tool_dependency.jl")
            result = backend_fixture_job(directory,fixtures,"undeclared-tool-dependency",:script,entry)
            @test result["status"] == "analysis_incomplete"
            @test !result["full_analysis_complete"]
            @test pkgdir(JETSweep) ∉ result["effective_load_paths"]
        end
        @testset "worker globals are not script bindings" begin
            entry = joinpath(fixtures,"scripts","undeclared_tool_global.jl")
            result = backend_fixture_job(directory,fixtures,"undeclared-tool-global",:script,entry)
            @test result["full_analysis_complete"]
            @test result["script_context_strategy"] == "fresh_module_with_virtual_main_prelude"
            @test all(line -> any(row -> row["file"] == entry && row["line"] == line &&
                occursin("undef-global-var",row["code"]),result["diagnostics"]),1:2)
        end
        @testset "explicit Main uses the isolated script context" begin
            entry = joinpath(fixtures,"scripts","isolated_main.jl")
            result = backend_fixture_job(directory,fixtures,"isolated-main",:script,entry)
            @test result["full_analysis_complete"]
            @test result["status"] == "clean"
            @test result["script_context_strategy"] == "fresh_module_with_virtual_main_prelude"
        end
        @testset "existing caches mode avoids target precompile workloads" begin
            package_root = joinpath(fixtures,"BackendPrecompileWitness")
            entry = joinpath(package_root,"src","BackendPrecompileWitness.jl")
            marker = joinpath(package_root,"src","NATIVE_PRECOMPILE_RAN")
            @test !isfile(marker)
            result = backend_fixture_job(directory,fixtures,"precompile-witness",:package,entry;
                owner=package_root,project=joinpath(package_root,"Project.toml"))
            @test result["full_analysis_complete"]
            @test !isfile(marker)
            # Prove the marker is an effective witness in a separate cold depot.
            # The analyzer itself must never enter this generating-output branch.
            command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=yes --project=$package_root -e 'using BackendPrecompileWitness'`
            environment = merge(copy(ENV),Dict("JULIA_DEPOT_PATH"=>joinpath(directory,"cold-depot"),
                "JULIA_PKG_PRECOMPILE_AUTO"=>"0"))
            run(pipeline(setenv(command,environment);stdout=devnull,stderr=devnull))
            @test isfile(marker)
        end
    end
end
