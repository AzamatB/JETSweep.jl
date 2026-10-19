using Test, JETSweep, TOML

function backend_context_write(root, path, source)
    file = joinpath(root,path)
    mkpath(dirname(file))
    write(file,source)
    return file
end

function backend_context_sweep(root, output)
    result = sweep(root; options=SweepOptions(; output, jobs=2, threads=1,
        gpu_devices=["none"], instantiate=false, timeout=180.0, fail_severity=:none), io=devnull)
    report = TOML.parsefile(joinpath(output,"report.toml"))
    @test isempty(report["input_changes"])
    return result,report
end

@testset "external generated documents preserve configuration path scopes" begin
    mktempdir() do directory
        root = joinpath(directory,"workspace")
        backend_context_write(root,"Project.toml","[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")
        backend_context_write(root,"test/runtests.jl","""
            using Test
            const HEADER_DIRECTORY = @__DIR__
            const HEADER_ASKED = split(get(ENV,"JETSWEEP_HEADER_SELECTOR","leaf"),",")
            const HEADER_RUN = filter(in(HEADER_ASKED),["leaf"])
            const HeaderSelection = Val{Symbol(only(HEADER_RUN))}
            context_directory() = HEADER_DIRECTORY
            include("test_leaf.jl")
            """)
        leaf = backend_context_write(root,"test/test_leaf.jl","""
            header_failure(::HeaderSelection) = sin(context_directory())
            """)
        scoped = backend_context_write(root,"scripts/scoped.jl","""
            const SCRIPT_SELECTOR = get(ENV,"JETSWEEP_SCRIPT_SELECTOR","selected")
            const ScriptSelection = Val{Symbol(SCRIPT_SELECTOR)}
            scoped_failure(::ScriptSelection) = sin("scoped original source")
            """)
        unrelated = backend_context_write(root,"scripts/unrelated.jl",read(scoped,String))
        backend_context_write(root,"patterns.toml",join([
            "[[full_analysis.concretization_patterns]]\npath = \"**/context-entry.jl\"\npattern = \"const $name = x_\"\n"
            for name in ("HEADER_ASKED","HEADER_RUN","HeaderSelection")],"\n") * """
            [[full_analysis.concretization_patterns]]
            path = "scripts/scoped.jl"
            pattern = "const SCRIPT_SELECTOR = x_"
            [[full_analysis.concretization_patterns]]
            path = "scripts/scoped.jl"
            pattern = "const ScriptSelection = x_"
            """)
        backend_context_write(root,".JETSweep.toml","""
            [[jobs]]
            match = "**"
            jetls_config = "patterns.toml"
            """)
        _, report = backend_context_sweep(root,joinpath(directory,"external-report"))
        for file in (leaf,scoped)
            row = only(filter(row -> row["entry"] == file,report["results"]))
            @test row["full_analysis_complete"]
            @test any(d -> d["file"] == file && d["code"] == "inference/method-error",row["diagnostics"])
            @test row["configuration_root"] == root
            document = only(row["generated_documents"])
            @test startswith(document["virtual_file"],root * "/")
            @test !ispath(document["virtual_file"])
            @test isfile(document["artifact"])
            @test row["analysis_entry_uri"] == document["uri"]
            @test isempty(row["internal_errors"])
        end
        unrelated_result = only(filter(row -> row["entry"] == unrelated,report["results"]))
        @test !unrelated_result["full_analysis_complete"]
        @test any(d -> d["code"] == "toplevel/missing-concretization",unrelated_result["diagnostics"])
        @test !isdir(joinpath(root,"jetsweep-virtual"))
    end
end

@testset "late original includes retain native module identity and reject unknown transforms" begin
    mktempdir() do directory
        root = joinpath(directory,"workspace")
        owner = joinpath(root,"LazyWitness")
        backend_context_write(owner,"Project.toml","""
            name = "LazyWitness"
            uuid = "f1c16750-9935-493f-a959-a5bdd3be2382"
            version = "0.1.0"
            """)
        entry = backend_context_write(owner,"src/LazyWitness.jl","""
            module LazyWitness
            load!() = Base.include(@__MODULE__,joinpath(@__DIR__,"implementation.jl"))
            end
            """)
        implementation = backend_context_write(owner,"src/implementation.jl","""
            module Implementation
            struct PrivateTag end
            open(get(ENV,"JETSWEEP_LAZY_COUNTER",""),"a") do io
                println(io,"loaded")
            end
            include("helper.jl")
            end
            """)
        helper = backend_context_write(owner,"src/helper.jl",
            "lazy_failure(::PrivateTag) = sin(\"late loaded original\")\n")
        setup = backend_context_write(directory,"setup.jl","import LazyWitness\nLazyWitness.load!()\n")
        counter = joinpath(directory,"load-count.txt")
        mapped_owner = joinpath(root,"MappedWitness")
        backend_context_write(mapped_owner,"Project.toml","""
            name = "MappedWitness"
            uuid = "ee27e4ce-0c9b-4f37-b531-5c39858e39c2"
            version = "0.1.0"
            """)
        mapped_entry = backend_context_write(mapped_owner,"src/MappedWitness.jl","""
            module MappedWitness
            rewrite(ex) = ex isa Expr && ex.head === :(=) ? :(mapped_value() = 1) : ex
            load!() = Base.include(rewrite,@__MODULE__,joinpath(@__DIR__,"mapped.jl"))
            end
            """)
        backend_context_write(mapped_owner,"src/mapped.jl","mapped_value() = sin(\"not the loaded method\")\n")
        mapped_setup = backend_context_write(directory,"mapped-setup.jl","import MappedWitness\nMappedWitness.load!()\n")
        backend_context_write(root,".JETSweep.toml","""
            [[jobs]]
            match = "LazyWitness/src/LazyWitness.jl"
            setup = [$(repr(setup))]
            [jobs.env]
            JETSWEEP_LAZY_COUNTER = $(repr(counter))
            [[jobs]]
            match = "MappedWitness/src/MappedWitness.jl"
            setup = [$(repr(mapped_setup))]
            """)
        _,report = backend_context_sweep(root,joinpath(directory,"report"))
        row = only(filter(row -> row["entry"] == entry && row["kind"] == "package",report["results"]))
        @test row["full_analysis_complete"]
        @test all(file -> file in row["analyzed_files"],(entry,implementation,helper))
        @test any(d -> d["file"] == helper && d["code"] == "inference/method-error",row["diagnostics"])
        @test any(sig -> sig["file"] == helper && sig["module"] == "LazyWitness.Implementation" && sig["analysis_verified"],row["signatures"])
        registrations = row["observed_source_registrations"]
        @test Set(item["file"] for item in registrations) == Set([implementation,helper])
        @test all(item -> item["mapexpr"] == "Base.identity",registrations)
        @test readlines(counter) == ["loaded"]
        @test isempty(row["internal_errors"])
        mapped = only(filter(row -> row["entry"] == mapped_entry && row["kind"] == "package",report["results"]))
        @test mapped["status"] == "unsupported_backend"
        @test !mapped["full_analysis_complete"]
        @test occursin("no proven identity include edge",mapped["error"])
    end
end
