using Test, JETSweep, TOML

function integration_sandbox(function_)
    get(ENV,"JETSWEEP_KEEP_INTEGRATION","") == "1" || return mktempdir(function_)
    directory = mktempdir(;cleanup=false)
    @info "Retaining integration artifacts" directory
    return function_(directory)
end

function integration_write(root::String, relative::String, contents::String)
    path = joinpath(root,relative)
    mkpath(dirname(path))
    write(path,contents)
    return path
end

function integration_cli(root::String, output::String)
    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -m JETSweep --jobs 2 --threads 1 --gpus none --timeout 180 --no-instantiate --fail-on none --output $output $root`
    log = output * ".log"
    code = open(log,"w") do io
        process = run(pipeline(command;stdout=io,stderr=io);wait=false)
        if timedwait(() -> process_exited(process),420.0) === :timed_out
            kill(process)
            wait(process)
            error("Integration CLI timed out; log: $log")
        end
        wait(process)
        return process.exitcode
    end
    report_file = joinpath(output,"report.toml")
    isfile(report_file) || error("CLI emitted no aggregate report (exit $code):\n$(read(log,String))")
    return code, TOML.parsefile(report_file), log
end

function integration_options(output::String)
    return SweepOptions(;jobs=2,threads=1,gpu_devices=["none"],timeout=180.0,
        instantiate=false,fail_severity=:none,output)
end

integration_method_error(report,file) = any(row -> row["file"] == file &&
    startswith(row["code"],"inference/method-error"),report["diagnostics"])

@testset "public CLI reaches nested packages, tests, extensions, and inactive source" begin
    integration_sandbox() do directory
        root = joinpath(directory,"workspace")
        mkpath(root)
        integration_write(root,"Project.toml","[deps]\n")
        owner = joinpath(root,"packages","IntegrationOwner")
        integration_write(owner,"Project.toml","""
            name = "IntegrationOwner"
            uuid = "0d193ae3-2e6a-4498-9e56-07c626f67fd4"
            version = "0.1.0"
            [weakdeps]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [extensions]
            IntegrationOwnerTestExt = "Test"
            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [targets]
            test = ["Test"]
            """)
        package_source = integration_write(owner,"src/IntegrationOwner.jl","""
            module IntegrationOwner
            export helper_string
            helper_string() = "integration failure"
            package_failure(x::Int) = sin("package failure") + x
            if false
                include("inactive.jl")
            end
            end
            """)
        inactive = integration_write(owner,"src/inactive.jl",
            "inactive_failure(x::Int) = cos(helper_string()) + x\n")
        extension = integration_write(owner,"ext/IntegrationOwnerTestExt.jl","""
            module IntegrationOwnerTestExt
            using IntegrationOwner
            using Test
            extension_failure(x::Int) = sin(IntegrationOwner.helper_string()) + x
            end
            """)
        test_entry = integration_write(owner,"test/runtests.jl","""
            using Test
            using IntegrationOwner
            test_context_value() = "test context failure"
            @testset "functional campaign remains abstract" begin
                write(joinpath(@__DIR__,"FUNCTIONAL_CAMPAIGN_RAN"),"unexpected")
                include("test_case.jl")
            end
            """)
        test_case = integration_write(owner,"test/test_case.jl",
            "test_failure(x::Int) = sin(test_context_value()) + x\n")
        nested = joinpath(owner,"tools","IntegrationNested")
        integration_write(nested,"Project.toml","""
            name = "IntegrationNested"
            uuid = "ce4c9674-3050-4dab-b521-d3246680e499"
            version = "0.1.0"
            """)
        nested_source = integration_write(nested,"src/IntegrationNested.jl",
            "module IntegrationNested\nsquare(x::Int) = x*x\nend\n")
        script = integration_write(root,"scripts/failing.jl",
            "script_failure(x::Int) = sin(\"script failure\") + x\n")
        configuration = integration_write(root,"analysis-config.toml",
            "[full_analysis]\nconcretization_timeout = 7.25\n")
        integration_write(root,".JETSweep.toml","""
            [[jobs]]
            match = "**"
            jetls_config = "analysis-config.toml"
            """)

        output = joinpath(directory,"report")
        code, report, _ = integration_cli(root,output)
        @test code == 2
        @test report["exit_code"] == 2
        @test report["status"] == "incomplete"
        @test report["files"] == 7
        @test report["packages"] == 2
        @test isempty(report["discovery_issues"])
        @test isempty(report["input_changes"])
        @test Set(row["path"] for row in report["coverage"]) ==
            Set([package_source,inactive,extension,test_entry,test_case,nested_source,script])
        for file in (package_source,inactive,extension,test_case,script)
            if !integration_method_error(report,file)
                @info "Unexpected integration diagnostic" file diagnostics=filter(row -> row["file"] == file,report["diagnostics"])
            end
            @test integration_method_error(report,file)
        end
        @test !isfile(joinpath(owner,"test","FUNCTIONAL_CAMPAIGN_RAN"))

        parent = only(filter(row -> row["entry"] == package_source && row["kind"] == "package",report["results"]))
        @test !parent["full_analysis_complete"]
        @test inactive in parent["missing_files"]
        supplemental = only(filter(row -> row["entry"] == inactive && row["kind"] == "source",report["results"]))
        @test supplemental["full_analysis_complete"]
        @test supplemental["supplemental_parent_job"] == parent["job_id"]
        @test supplemental["original_file"] == inactive
        @test supplemental["context_mode"] == "disconnected_package_source"
        @test only(filter(row -> row["path"] == inactive,report["coverage"]))["status"] == "covered"
        @test isfile(joinpath(output,"supplemental-plan.toml"))
        @test only(filter(row -> row["entry"] == nested_source,report["results"]))["full_analysis_complete"]
        extension_result = only(filter(row -> row["entry"] == extension && row["kind"] == "extension",report["results"]))
        @test extension_result["full_analysis_complete"]
        @test extension_result["parent_identity"]["uuid"] == "0d193ae3-2e6a-4498-9e56-07c626f67fd4"
        @test extension_result["requested_triggers"][1]["uuid"] == "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        @test only(filter(row -> row["entry"] == test_case,report["results"]))["full_analysis_complete"]

        for result in report["results"]
            generated = joinpath(output,"jobs",result["job_id"],"config",".JETLSConfig.toml")
            @test isfile(generated)
            settings = TOML.parsefile(generated)
            @test settings["full_analysis"]["concretization_timeout"] == 7.25
            @test settings["full_analysis"]["auto_instantiate"] == "never"
            @test settings["diagnostic"]["all_files"]
            @test settings["initialization_options"]["reuse_native_inference"] == false
            @test result["source_hashes_before"][generated] == JETSweep.file_digest(generated)
            request = TOML.parsefile(joinpath(output,"jobs",result["job_id"],"job.toml"))
            @test request["config_directory"] == dirname(generated)
            @test request["job"]["context"]["configuration"] == configuration
        end
        plan = TOML.parsefile(joinpath(output,"plan.toml"))
        @test plan["execution"]["workers"] == 2
        @test isfile(joinpath(output,"summary.txt"))
    end
end

@testset "invalid JETLS configurations preserve the aggregate and other jobs" begin
    integration_sandbox() do directory
        root = joinpath(directory,"workspace")
        integration_write(root,"Project.toml","[deps]\n")
        good = integration_write(root,"good.jl","good(x::Int) = x + 1\n")
        suppressed = integration_write(root,"suppressed.jl","suppressed(x::Int) = x + 1\n")
        malformed = integration_write(root,"malformed_config.jl","malformed_config(x::Int) = x + 1\n")
        integration_write(root,"suppressed.toml","[diagnostic]\nenabled = false\n")
        integration_write(root,"malformed.toml","[full_analysis\n")
        integration_write(root,".JETSweep.toml","""
            [[jobs]]
            match = "suppressed.jl"
            jetls_config = "suppressed.toml"
            [[jobs]]
            match = "malformed_config.jl"
            jetls_config = "malformed.toml"
            """)
        output = joinpath(directory,"report")
        result = sweep(root;options=integration_options(output),io=devnull)
        report = TOML.parsefile(joinpath(output,"report.toml"))
        @test result.exit_code == 2
        @test report["files"] == 3
        @test length(report["results"]) == 3
        @test only(filter(row -> row["entry"] == good,report["results"]))["full_analysis_complete"]
        for path in (suppressed,malformed)
            row = only(filter(row -> row["entry"] == path,report["results"]))
            @test row["status"] == "invalid_configuration"
            @test !row["full_analysis_complete"]
            @test !isempty(row["error"])
            @test isfile(row["log"])
        end
        @test Set(row["path"] for row in report["coverage"]) == Set([good,suppressed,malformed])
        @test isempty(report["input_changes"])
    end
end

@testset "malformed and unavailable project contexts remain inventoried" begin
    integration_sandbox() do directory
        root = joinpath(directory,"workspace")
        integration_write(root,"Project.toml","[deps]\n")
        good = integration_write(root,"good.jl","healthy(x::Int) = x + 1\n")
        integration_write(root,"malformed/Project.toml","name = [\n")
        malformed = integration_write(root,"malformed/src/Broken.jl","unreachable(x::Int) = x\n")
        integration_write(root,"unavailable/Project.toml","""
            name = "IntegrationUnavailable"
            uuid = "0ce4e776-52a5-46b7-8139-c2eb1a5fc501"
            version = "0.1.0"
            [deps]
            IntegrationMissing = "b0808ad9-6970-4a0e-8f56-c03717a8eba4"
            [sources]
            IntegrationMissing = {path = "missing-dependency"}
            """)
        unavailable = integration_write(root,"unavailable/src/IntegrationUnavailable.jl",
            "module IntegrationUnavailable\nusing IntegrationMissing\nend\n")
        output = joinpath(directory,"report")
        result = sweep(root;options=integration_options(output),io=devnull)
        report = TOML.parsefile(joinpath(output,"report.toml"))
        @test result.exit_code == 2
        @test report["files"] == 3
        @test !isempty(report["discovery_issues"])
        @test Set(row["path"] for row in report["coverage"]) == Set([good,malformed,unavailable])
        @test only(filter(row -> row["entry"] == good,report["results"]))["full_analysis_complete"]
        for path in (malformed,unavailable)
            row = only(filter(row -> row["entry"] == path,report["results"]))
            @test row["status"] == "environment_unavailable"
            @test !row["full_analysis_complete"]
            @test !isempty(row["error"])
        end
        @test isempty(report["input_changes"])
    end
end

@testset "JuliaProject ownership, ignored Project metadata, and alternate entry" begin
    integration_sandbox() do directory
        root = joinpath(directory,"workspace")
        only_julia = joinpath(root,"only-julia")
        integration_write(only_julia,"JuliaProject.toml","""
            name = "IntegrationJuliaOnly"
            uuid = "900c08b2-24a2-41ba-9358-377b0d14765c"
            version = "0.1.0"
            [weakdeps]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [extensions]
            IntegrationJuliaOnlyTestExt = "Test"
            """)
        only_source = integration_write(only_julia,"src/IntegrationJuliaOnly.jl",
            "module IntegrationJuliaOnly\njulia_only_failure(x::Int) = sin(\"only JuliaProject\") + x\nend\n")
        only_extension = integration_write(only_julia,"ext/IntegrationJuliaOnlyTestExt.jl","""
            module IntegrationJuliaOnlyTestExt
            using IntegrationJuliaOnly
            using Test
            extension_failure(x::Int) = cos("JuliaProject extension") + x
            end
            """)
        preferred = joinpath(root,"preferred")
        integration_write(preferred,"JuliaProject.toml","""
            name = "IntegrationPreferred"
            uuid = "2da9bdf6-a04e-4196-b36d-1f0b70feecf9"
            version = "0.1.0"
            entryfile = "lib/Start.jl"
            """)
        integration_write(preferred,"Project.toml","""
            name = "IgnoredWrongOwner"
            uuid = "0b32685a-b7c9-4dc0-9c9f-e25e99092d0d"
            version = "99.0.0"
            """)
        preferred_source = integration_write(preferred,"lib/Start.jl","""
            module IntegrationPreferred
            struct PrivateContext end
            include("support.jl")
            end
            """)
        support = integration_write(preferred,"lib/support.jl",
            "private_context_failure(::PrivateContext) = sin(\"alternate entry helper\")\n")
        output = joinpath(directory,"report")
        result = sweep(root;options=integration_options(output),io=devnull)
        report = TOML.parsefile(joinpath(output,"report.toml"))
        @test result.exit_code == 0 # Findings retained, with fail-on=none.
        @test report["files"] == 4
        @test report["packages"] == 2
        @test isempty(report["discovery_issues"])
        @test all(row -> row["full_analysis_complete"],report["results"])
        @test all(file -> integration_method_error(report,file),[only_source,only_extension,support])
        @test all(row -> row["status"] == "covered",report["coverage"])
        preferred_result = only(filter(row -> row["entry"] == preferred_source,report["results"]))
        @test preferred_result["kind"] == "package"
        @test preferred_result["parent_identity"]["name"] == "IntegrationPreferred"
        @test preferred_result["parent_identity"]["uuid"] == "2da9bdf6-a04e-4196-b36d-1f0b70feecf9"
        @test preferred_result["parent_identity"]["source"] == preferred_source
        @test support in preferred_result["analyzed_files"]
        @test !any(row -> row["entry"] == support,report["results"])
        @test !any(row -> occursin("undef-global-var",row["code"]),report["diagnostics"])
        extension_result = only(filter(row -> row["entry"] == only_extension,report["results"]))
        loaded = only(filter(row -> row["parent"]["name"] == "IntegrationJuliaOnly",extension_result["loaded_extensions"]))
        @test loaded["parent"]["uuid"] == "900c08b2-24a2-41ba-9358-377b0d14765c"
        @test loaded["extension"]["source"] == only_extension
        @test isempty(report["input_changes"])
    end
end

@testset "actual include behavior determines completion" begin
    integration_sandbox() do directory
        root = joinpath(directory,"workspace")
        integration_write(root,"Project.toml","[deps]\n")
        guarded = integration_write(root,"guarded.jl","""
            if false
                include("missing_script_optional.jl")
            end
            guarded_value(x::Int) = x + 1
            """)
        unconditional = integration_write(root,"unconditional.jl",
            "include(\"missing_script_required.jl\")\n")
        package = joinpath(root,"optional-package")
        integration_write(package,"Project.toml","""
            name = "IntegrationOptional"
            uuid = "4c67aa2f-c709-48e5-a6b7-a7c59c2b3d67"
            version = "0.1.0"
            """)
        package_source = integration_write(package,"src/IntegrationOptional.jl","""
            module IntegrationOptional
            const optional_file = joinpath(@__DIR__,"missing_package_optional.jl")
            if isfile(optional_file)
                include(optional_file)
            end
            optional_value(x::Int) = x + 1
            end
            """)
        output = joinpath(directory,"report")
        result = sweep(root;options=integration_options(output),io=devnull)
        report = TOML.parsefile(joinpath(output,"report.toml"))
        @test result.exit_code == 2
        @test report["files"] == 3
        for source in (guarded,package_source)
            row = only(filter(row -> row["entry"] == source,report["results"]))
            @test row["full_analysis_complete"]
            @test isempty(row["blocking_issues"])
            @test !isempty(row["context_issues"])
        end
        failed = only(filter(row -> row["entry"] == unconditional,report["results"]))
        @test failed["status"] == "analysis_incomplete"
        @test !failed["full_analysis_complete"]
        @test isempty(failed["blocking_issues"])
        @test any(row -> startswith(row["code"],"toplevel/"),failed["diagnostics"])
        @test isempty(report["input_changes"])
    end
end
