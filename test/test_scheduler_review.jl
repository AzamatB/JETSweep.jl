using Test, JETSweep

@testset "Snapshots retain metadata, configuration, and worker entrypoints" begin
    mktempdir() do root
        package = joinpath(root, "nested project")
        mkpath(package)
        write(joinpath(package, "source.jl"), "identity_value(x) = x\n")
        metadata = ["Project.toml", "Manifest.toml", "Manifest-v1.13.toml",
                    "JuliaManifest-v1.12.toml", "LocalPreferences.toml", "Artifacts.toml",
                    ".JETSweep.toml", ".JETLSConfig.toml"]
        for name in metadata
            write(joinpath(package, name), "# metadata\n")
        end
        write(joinpath(root, ".JETLSConfig.toml"), "# root configuration\n")
        custom = joinpath(root, "custom-contexts.toml")
        write(custom, "# custom configuration\n")
        inventory = discover(root)
        jobs = plan(inventory)
        before = JETSweep.input_snapshot(inventory, jobs; config=custom)
        @test all(name -> haskey(before, joinpath(package, name)), metadata)
        @test haskey(before, custom)
        @test haskey(before, joinpath(root, ".JETLSConfig.toml"))
        @test haskey(before, joinpath(pkgdir(JETSweep), "scripts", "analyze.jl"))
        @test haskey(before, joinpath(pkgdir(JETSweep), "scripts", "prepare_environment.jl"))
        write(joinpath(package, "Project.toml"), "manifest = \"custom-lock.toml\"\n")
        write(joinpath(package, "custom-lock.toml"), "# selected nonstandard manifest\n")
        write(custom, "# changed configuration\n")
        after = JETSweep.input_snapshot(discover(root), jobs; config=custom)
        changed = JETSweep.changed_inputs(before, after)
        @test joinpath(package, "Project.toml") in changed
        @test joinpath(package, "custom-lock.toml") in changed
        @test custom in changed
        # Parse failures, newly preferred metadata, and deleted projects must
        # remain observable even when they alter the project's discovered record.
        write(joinpath(package, "JuliaProject.toml"), "[malformed\n")
        malformed = JETSweep.input_snapshot(discover(root), jobs; config=custom)
        @test joinpath(package, "JuliaProject.toml") in JETSweep.changed_inputs(after, malformed)
        rm(joinpath(package, "JuliaProject.toml"))
        rm(joinpath(package, "Project.toml"))
        removed = JETSweep.input_snapshot(discover(root), jobs; config=custom)
        @test joinpath(package, "Project.toml") in JETSweep.changed_inputs(malformed, removed)
        @test joinpath(package, "JuliaProject.toml") in JETSweep.changed_inputs(malformed, removed)
    end
end

@testset "Snapshots include configured external project metadata" begin
    mktempdir() do root
        mktempdir() do external
            file = joinpath(root, "source.jl")
            write(file, "nothing\n")
            write(joinpath(external, "Project.toml"), "[deps]\n")
            write(joinpath(external, "LocalPreferences.toml"), "# preferences\n")
            jobs = [JETSweep.AnalysisJob(id="external", kind=:script, entry=file,
                project=external, expected_files=[file], context=JETSweep.ContextSpec(project=external))]
            snapshot = JETSweep.input_snapshot(discover(root), jobs)
            @test haskey(snapshot, joinpath(external, "Project.toml"))
            @test haskey(snapshot, joinpath(external, "LocalPreferences.toml"))
        end
    end
end

function review_process_running(pid)
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 || return false
    if Sys.islinux()
        # An orphan killed by the test may briefly await reaping by PID 1.
        stat = try
            read("/proc/$pid/stat", String)
        catch
            return false
        end
        split(stat)[3] == "Z" && return false
    end
    return true
end

@testset "Worker descendants terminate after leader completion and timeout" begin
    if Sys.isunix()
        mktempdir() do directory
            for (name, script, timeout) in (
                ("completed", "sleep 60 & printf '%s %s' \$! \$\$ > \"\$1\"", 5.0),
                ("timed-out", "sh -c 'trap \"\" TERM; sleep 60' & printf '%s %s' \$! \$\$ > \"\$1\"; wait", 0.5),
            )
                pidfile = joinpath(directory, "$name.pid")
                command = Cmd(["/bin/sh", "-c", script, "jetsweep-process-test", pidfile])
                group = 0
                active = Set{Base.Process}()
                try
                    result = JETSweep._run_process(command, joinpath(directory, "$name.log"), timeout, active)
                    child, group = parse.(Int, split(read(pidfile, String)))
                    timedwait(() -> !review_process_running(child), 1.0; pollint=0.02)
                    @test !review_process_running(child)
                    @test result.timed_out == (name == "timed-out")
                    @test result.seconds < 8
                    @test isempty(active)
                finally
                    group == 0 || ccall(:kill, Cint, (Cint, Cint), -group, Base.SIGKILL)
                end
            end
            command = Cmd(["/bin/sh", "-c", "kill -TERM \$\$"])
            result = JETSweep._run_process(command, joinpath(directory, "signal.log"), 5.0, Set{Base.Process}())
            @test result.exit_code == 128 + Base.SIGTERM
            @test result.signal == Base.SIGTERM
            @test !result.timed_out
        end
    end
end
