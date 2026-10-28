# Planning: the analysis units of an inventory, their contexts and configuration.
@testsetup module Planning
using JETSweep, TOML, Test, UUIDs

const PLANNING_DATES = "ade2ca70-3891-5945-98fb-dc099432e06a"

const PLANNING_TEST = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

const PLANNING_OTHER = "5c0d4e38-7f43-4d0b-9a49-3b5bfbd1f6a1"

function planning_file(root::String, relative::String, content::String="")
    path = joinpath(root, relative)
    mkpath(dirname(path))
    write(path, content)
    return path
end

function planning_project(root::String, relative::String=".", data::Dict{String}=Dict{String,Any}();
                          file::String="Project.toml")
    directory = relative == "." ? root : joinpath(root, relative)
    mkpath(directory)
    open(io -> TOML.print(io, data), joinpath(directory, file), "w")
    return directory
end

planning_package(root::String, relative::String, name::String; extra...) =
    planning_project(root, relative, Dict{String,Any}("name" => name, "uuid" => string(uuid4()),
                                                      (String(k) => v for (k, v) in extra)...))

planning_context(project, owner, test=false, triggers=Dict{String,String}()) =
    JETSweep.Context(project, owner, test, triggers)

function planning_plan(root::String, file::String="")
    config = JETSweep.read_config(root, file)
    inventory = discover(root; config)
    return inventory, plan(inventory, config)
end

planning_unit(units, entry::String) = only(filter(unit -> unit.entry == entry, units))

planning_entries(units) = Set(unit.entry for unit in units)

planning_noted(unit, text) = any(note -> occursin(text, note), unit.notes)

planning_overrides(overrides) = (overrides.setup, overrides.args, overrides.env, overrides.jetls_config)

const PLANNING_NONE = (String[], String[], Dict{String,String}(), "")

function planning_invariants(inventory, units)
    paths = Set(source.path for source in inventory.sources)
    @test all(source -> any(unit -> source.path in unit.expected, units), inventory.sources)
    @test allunique(unit.id for unit in units)
    @test all(unit -> occursin(Regex("^$(unit.kind)-[0-9a-f]{12}\$"), unit.id), units)
    @test all(unit -> unit.entry in unit.expected && issorted(unit.expected), units)
    @test all(unit -> all(in(paths), unit.expected), units)
    @test all(unit -> issorted(unit.notes) && allunique(unit.notes), units)
    @test issorted(units; by=unit -> (unit.entry, unit.extension))
end

export PLANNING_DATES, PLANNING_NONE, PLANNING_OTHER, PLANNING_TEST, TOML, UUID, UUIDs, planning_context,
    planning_entries, planning_file, planning_invariants, planning_noted, planning_overrides, planning_package,
    planning_plan, planning_project, planning_unit, uuid4
end

@testitem "package units cover the owned files their entry reaches and their other sources" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        outer = planning_package(root, "Outer", "Outer")
        entry = planning_file(outer, "src/Outer.jl", """
            module Outer
            include("a.jl")
            include(joinpath(@__DIR__, "sub", "b.jl"))
            function load()
                include("lazy.jl")
            end
            include("../lib/Inner/src/Inner.jl")
            end
            """)
        a = planning_file(outer, "src/a.jl", "include(\"sub/b.jl\")\n")
        b = planning_file(outer, "src/sub/b.jl", "include(\"../a.jl\")\n")
        lazy = planning_file(outer, "src/lazy.jl")
        disconnected = planning_file(outer, "src/disconnected.jl", "disconnected(x) = x\n")
        inner = planning_package(outer, "lib/Inner", "Inner")
        inner_entry = planning_file(inner, "src/Inner.jl", "module Inner\ninclude(\"helper.jl\")\nend\n")
        inner_helper = planning_file(inner, "src/helper.jl")
        alternate = planning_package(root, "Alternate", "Alternate"; entryfile="lib/Main.jl")
        alternate_entry = planning_file(alternate, "lib/Main.jl",
                                        "module Alternate\ninclude(\"helper.jl\")\nend\n")
        alternate_helper = planning_file(alternate, "lib/helper.jl")
        broken = planning_package(root, "Broken", "Broken")
        planning_file(broken, "src/part.jl")
        inventory, units = planning_plan(root)

        @test sort([unit.entry for unit in units if unit.kind === :package]) ==
              sort([entry, inner_entry, alternate_entry])
        package = planning_unit(units, entry)
        @test package.kind === :package
        # Sources the entry does not include statically are expected too: the sweep analyzes
        # those that loading leaves out as orphan units.
        @test package.expected == sort([entry, a, b, lazy, disconnected])
        @test package.context == planning_context(outer, outer)
        @test package.driver == package.extension == ""
        @test isempty(package.notes)
        @test planning_overrides(package.overrides) == PLANNING_NONE
        nested = planning_unit(units, inner_entry)
        @test nested.expected == sort([inner_entry, inner_helper])
        @test nested.context == planning_context(inner, inner)
        @test count(unit -> inner_helper in unit.expected, units) == 1
        @test !(disconnected in planning_entries(units))

        @test only(filter(source -> source.path == alternate_helper, inventory.sources)).kind === :script
        @test planning_unit(units, alternate_entry).expected == sort([alternate_entry, alternate_helper])
        @test !(alternate_helper in planning_entries(units))
        @test count(unit -> alternate_helper in unit.expected, units) == 1
        @test !any(unit -> unit.context.owner == broken && unit.kind in (:package, :orphan), units)
        @test length(units) == 4
        planning_invariants(inventory, units)
    end
end

@testitem "extension units for flat and directory layouts" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        host = planning_package(root, "Host", "Host";
            weakdeps=Dict("Dates" => PLANNING_DATES, "Other" => PLANNING_OTHER),
            extensions=Dict("FlatExt" => "Dates", "DirExt" => ["Dates", "Other"], "BothExt" => "Other",
                            "AbsentExt" => "Dates"))
        entry = planning_file(host, "src/Host.jl", "module Host\nend\n")
        flat = planning_file(host, "ext/FlatExt.jl", "module FlatExt\nend\n")
        nested = planning_file(host, "ext/DirExt/DirExt.jl", "module DirExt\ninclude(\"helper.jl\")\nend\n")
        helper = planning_file(host, "ext/DirExt/helper.jl")
        stray = planning_file(host, "ext/DirExt/stray.jl")
        both_flat = planning_file(host, "ext/BothExt.jl", "module BothExt\nend\n")
        both_nested = planning_file(host, "ext/BothExt/BothExt.jl", "module BothExt\nend\n")
        undeclared = planning_file(host, "ext/Undeclared.jl")
        inventory, units = planning_plan(root)

        extensions = Dict(unit.extension => unit for unit in units if unit.kind === :extension)
        @test sort!(collect(keys(extensions))) == ["BothExt", "DirExt", "FlatExt"]
        @test extensions["FlatExt"].entry == flat
        @test extensions["FlatExt"].expected == [flat]
        @test extensions["FlatExt"].context == planning_context(host, host, false, Dict("Dates" => PLANNING_DATES))
        @test extensions["DirExt"].entry == nested
        @test extensions["DirExt"].expected == [nested, helper]
        @test extensions["DirExt"].context.triggers == Dict("Dates" => PLANNING_DATES, "Other" => PLANNING_OTHER)
        @test extensions["BothExt"].entry == both_flat
        @test all(unit -> unit.driver == "" && !unit.context.test, values(extensions))
        @test planning_unit(units, entry).kind === :package
        @test planning_unit(units, entry).expected == [entry]
        @test planning_unit(units, both_nested).kind === :orphan
        @test planning_unit(units, undeclared).kind === :orphan
        @test planning_unit(units, undeclared).context == planning_context(host, host)
        # A source in an extension's directory that it does not include belongs to it.
        @test planning_unit(units, stray).kind === :orphan
        @test planning_unit(units, stray).extension == "DirExt"
        @test planning_unit(units, stray).context == extensions["DirExt"].context
        @test planning_unit(units, undeclared).extension == ""
        @test !any(unit -> unit.extension == "AbsentExt", units)
        @test length(units) == 7
        planning_invariants(inventory, units)
    end
end

@testitem "test units: drivers, run-time includes and helpers" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        tested = planning_package(root, "Tested", "Tested")
        planning_file(tested, "src/Tested.jl", "module Tested\nend\n")
        environment = planning_project(tested, "test", Dict{String,Any}("deps" => Dict("Test" => PLANNING_TEST)))
        driver = planning_file(tested, "test/runtests.jl", """
            using Test, Tested
            include("setup.jl")
            include(joinpath(pkgdir(Tested), "test", "located.jl"))
            include(joinpath(dirname(pathof(Tested)), "../test/found.jl"))
            @testset "grouped" include("grouped.jl")
            const TESTS = ["unit_a.jl", "unit_b.jl"]
            for file in TESTS
                include(file)
            end
            function lazy()
                include("lazy.jl")
            end
            """)
        statics = [planning_file(tested, "test/$name.jl") for name in ("setup", "located", "found", "grouped")]
        unit_a = planning_file(tested, "test/unit_a.jl", "include(\"helpers/common.jl\")\n")
        unit_b = planning_file(tested, "test/unit_b.jl", "include(\"setup.jl\")\ninclude(\"helpers/common.jl\")\n")
        common = planning_file(tested, "test/helpers/common.jl")
        lazy = planning_file(tested, "test/lazy.jl")
        cycle_x = planning_file(tested, "test/cycle_x.jl", "include(\"cycle_y.jl\")\n")
        cycle_y = planning_file(tested, "test/cycle_y.jl", "include(\"cycle_x.jl\")\n")
        recursive = planning_file(tested, "test/recursive.jl", "include(@__FILE__)\n")
        sub_driver = planning_file(tested, "test/sub/runtests.jl", "for file in ARGS\n    include(file)\nend\n")
        deep = planning_file(tested, "test/sub/deep.jl")
        isolated_environment = planning_project(tested, "test/isolated")
        isolated = planning_file(tested, "test/isolated/check.jl")

        plain = planning_package(root, "Plain", "Plain")
        planning_file(plain, "src/Plain.jl", "module Plain\nend\n")
        plain_driver = planning_file(plain, "test/runtests.jl", "include(\"basic.jl\")\n")
        basic = planning_file(plain, "test/basic.jl")

        # A nested driver included statically is part of its outer driver's unit.
        nested = planning_package(root, "Nested", "Nested")
        planning_file(nested, "src/Nested.jl", "module Nested\nend\n")
        nested_driver = planning_file(nested, "test/runtests.jl",
                                      "@testset \"all\" begin\n    include(\"core/runtests.jl\")\nend\n")
        core_driver = planning_file(nested, "test/core/runtests.jl", "for file in ARGS\n    include(file)\nend\n")
        core_test = planning_file(nested, "test/core/test_x.jl")

        driverless = planning_package(root, "Driverless", "Driverless")
        planning_file(driverless, "src/Driverless.jl", "module Driverless\nend\n")
        driverless_environment = planning_project(driverless, "test"; file="JuliaProject.toml")
        only_test = planning_file(driverless, "test/only.jl")
        inventory, units = planning_plan(root)

        context = planning_context(environment, tested, true)
        main = planning_unit(units, driver)
        @test main.kind === :test
        @test main.driver == ""
        @test main.expected == sort([driver; statics])
        @test main.context == context
        @test main.notes == ["$driver:8: include target is only known at run time"]
        for file in [unit_a, unit_b, lazy, cycle_x, recursive]
            @test planning_unit(units, file).kind === :test
            @test planning_unit(units, file).driver == driver
            @test planning_unit(units, file).context == context
        end
        @test planning_unit(units, unit_a).expected == sort([unit_a, common])
        @test planning_unit(units, unit_b).expected == [unit_b]
        @test planning_unit(units, lazy).expected == [lazy]
        @test planning_unit(units, cycle_x).expected == [cycle_x, cycle_y]
        @test planning_unit(units, recursive).expected == [recursive]
        @test isdisjoint(planning_entries(units), vcat(common, cycle_y, statics))
        # A nested driver the outer one does not include statically runs under it.
        @test planning_unit(units, sub_driver).kind === :test
        @test planning_unit(units, sub_driver).driver == driver
        @test planning_unit(units, sub_driver).expected == [sub_driver]
        @test planning_unit(units, sub_driver).context == context
        @test length(unique(unit.context for unit in units if unit.context.owner == tested)) == 2
        @test planning_unit(units, deep).driver == sub_driver
        @test planning_unit(units, deep).expected == [deep]
        @test planning_unit(units, isolated).kind === :script
        @test planning_unit(units, isolated).context == planning_context(isolated_environment, "")

        @test planning_unit(units, plain_driver).expected == sort([plain_driver, basic])
        @test planning_unit(units, plain_driver).context == planning_context(plain, plain, true)
        @test !(basic in planning_entries(units))
        @test planning_unit(units, nested_driver).expected == [core_driver, nested_driver]
        @test !(core_driver in planning_entries(units))
        @test planning_unit(units, core_test).driver == nested_driver
        @test planning_unit(units, only_test).kind === :test
        @test planning_unit(units, only_test).driver == ""
        @test planning_unit(units, only_test).context == planning_context(driverless_environment, driverless, true)
        planning_invariants(inventory, units)
    end
end

@testitem "script units group by include roots in their nearest environment" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        main = planning_file(root, "main.jl", "include(\"lib/util.jl\")\n")
        util = planning_file(root, "lib/util.jl")
        first_script = planning_file(root, "first.jl", "include(\"shared.jl\")\n")
        second_script = planning_file(root, "second.jl", "include(\"shared.jl\")\n")
        shared = planning_file(root, "shared.jl")
        loop_a = planning_file(root, "loop/a.jl", "include(\"b.jl\")\n")
        loop_b = planning_file(root, "loop/b.jl", "include(\"a.jl\")\n")
        tool = planning_package(root, "Tool", "Tool")
        planning_file(tool, "src/Tool.jl", "module Tool\nend\n")
        run = planning_file(tool, "scripts/run.jl", "include(\"common.jl\")\n")
        common = planning_file(tool, "scripts/common.jl")
        docs = planning_project(tool, "docs")
        make = planning_file(tool, "docs/make.jl")
        inventory, units = planning_plan(root)

        loose = planning_context("", "")
        @test planning_unit(units, main).kind === :script
        @test planning_unit(units, main).expected == sort([main, util])
        @test planning_unit(units, main).context == loose
        @test planning_unit(units, main).driver == ""
        @test planning_unit(units, first_script).expected == sort([first_script, shared])
        @test planning_unit(units, second_script).expected == [second_script]
        @test planning_unit(units, loop_a).expected == [loop_a, loop_b]
        @test isdisjoint(planning_entries(units), [util, shared, loop_b, common])
        @test planning_unit(units, run).expected == sort([run, common])
        # A package's own scripts use its test environment, a superset of the package's.
        @test planning_unit(units, run).context == JETSweep.Context(tool, tool, true, Dict{String,String}())
        @test planning_unit(units, make).context == planning_context(docs, "")
        @test count(unit -> unit.kind === :script, units) == length(units) - 1
        @test length(units) == 7
        planning_invariants(inventory, units)
    end
end

@testitem "files an include cycle reaches are covered by the cycle's entry" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        leaf = planning_file(root, "a.jl")
        inner = [planning_file(root, "b.jl", "include(\"c.jl\")\n"),
                 planning_file(root, "c.jl", "include(\"b.jl\")\n")]
        outer = [planning_file(root, "m.jl", "include(\"n.jl\")\n"),
                 planning_file(root, "n.jl", "include(\"m.jl\")\ninclude(\"a.jl\")\ninclude(\"b.jl\")\n")]
        inventory, units = planning_plan(root)
        @test [unit.entry for unit in units] == [first(outer)]
        @test [unit.expected for unit in units] == [[leaf; inner; outer]]
        planning_invariants(inventory, units)
    end
end

@testitem "a tree without Julia files plans no units" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        @test isempty(last(planning_plan(root)))
        planning_file(root, "README.md", "# Notes\n")
        planning_project(root, "env")
        inventory, units = planning_plan(root)
        @test isempty(inventory.sources) && !isempty(inventory.projects)
        @test isempty(units)
    end
end

@testitem "notes record dynamic includes and parse failures" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        dynamic = planning_file(root, "dynamic.jl", "include(ARGS[1])\n")
        broken = planning_file(root, "broken.jl", "function bad(\n")
        clean = planning_file(root, "clean.jl", "const x = 1\n")
        conditional = planning_file(root, "conditional.jl",
            "if flag\n    file = \"a.jl\"\nelse\n    file = \"b.jl\"\nend\ninclude(file)\n")
        absent = planning_file(root, "absent.jl", "include(\"nowhere.jl\")\n")
        side = planning_file(root, "side.jl", """
            write(joinpath(@__DIR__, "executed"), "")
            include(touch(joinpath(@__DIR__, "touched.jl")))
            """)
        other = planning_package(root, "Other", "Other")
        planning_file(other, "src/Other.jl", "module Other\nend\n")
        sibling = planning_file(other, "extra.jl")
        noted = planning_package(root, "Noted", "Noted")
        entry = planning_file(noted, "src/Noted.jl", """
            module Noted
            include("parts.jl")
            include(name)
            include(joinpath(pkgdir(Other), "extra.jl"))
            end
            """)
        parts = planning_file(noted, "src/parts.jl", "function f(\n")
        orphan = planning_file(noted, "src/orphan.jl", "include(readline())\n")
        inventory, units = planning_plan(root)

        @test planning_noted(planning_unit(units, dynamic), "$dynamic:1: include target is only known at run time")
        @test planning_noted(planning_unit(units, broken), "$broken:1: cannot be parsed")
        @test isempty(planning_unit(units, clean).notes)
        @test planning_noted(planning_unit(units, conditional), "$conditional:6: include target is only known")
        package = planning_unit(units, entry)
        @test package.expected == sort([entry, parts, orphan])
        @test planning_noted(package, "$entry:3: include target is only known at run time")
        @test planning_noted(package, "$parts:1: cannot be parsed")
        @test planning_noted(package, "$entry:4: include target is only known at run time")
        @test planning_unit(units, sibling).context == JETSweep.Context(other, other, true, Dict{String,String}())
        @test planning_unit(units, absent).expected == [absent]
        @test planning_noted(planning_unit(units, side), "$side:2: include target is only known at run time")
        @test !ispath(joinpath(root, "executed")) && !ispath(joinpath(root, "touched.jl"))
        @test !(orphan in planning_entries(units))
        @test planning_noted(package, "$orphan:1: include target is only known at run time")
        planning_invariants(inventory, units)
    end
end

@testitem "unit ids are deterministic, unique and relative to the root" setup=[Planning] begin
    function planning_workspace(root)
        package = planning_package(root, "Pkg", "Pkg"; weakdeps=Dict("Dates" => PLANNING_DATES),
                                   extensions=Dict("PkgDatesExt" => "Dates"))
        planning_file(package, "src/Pkg.jl", "module Pkg\ninclude(\"part.jl\")\nend\n")
        planning_file(package, "src/part.jl")
        planning_file(package, "src/unused.jl")
        planning_file(package, "ext/PkgDatesExt.jl")
        planning_file(package, "test/runtests.jl", "for file in ARGS\n    include(file)\nend\n")
        planning_file(package, "test/case.jl")
        planning_file(root, "script.jl")
        return root
    end
    mktempdir() do directory
        first_root = planning_workspace(mkpath(joinpath(realpath(directory), "first")))
        second_root = planning_workspace(mkpath(joinpath(realpath(directory), "second")))
        inventory, units = planning_plan(first_root)
        @test sort!([unit.kind for unit in units]) == [:extension, :package, :script, :test, :test]
        @test [unit.id for unit in units] == [unit.id for unit in plan(inventory)]
        @test [unit.id for unit in units] == [unit.id for unit in last(planning_plan(second_root))]
        package = only(filter(unit -> unit.kind === :package, units))
        extension = only(filter(unit -> unit.kind === :extension, units))
        @test package.id != extension.id
        planning_invariants(inventory, units)
        planning_file(first_root, "later.jl")
        @test [unit.id for unit in units] ⊆ [unit.id for unit in last(planning_plan(first_root))]
    end
end

@testitem "excluded files are not planned" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        host = planning_package(root, "Host", "Host"; weakdeps=Dict("Dates" => PLANNING_DATES),
                                extensions=Dict("HostDatesExt" => "Dates"))
        planning_file(host, "src/Host.jl", "module Host\nend\n")
        planning_file(host, "ext/HostDatesExt.jl")
        driver = planning_file(host, "test/runtests.jl")
        partial = planning_package(root, "Partial", "Partial")
        entry = planning_file(partial, "src/Partial.jl",
                              "module Partial\ninclude(\"generated.jl\")\ninclude(\"kept.jl\")\nend\n")
        planning_file(partial, "src/generated.jl")
        kept = planning_file(partial, "src/kept.jl")
        planning_file(root, ".JETSweep.toml", "exclude = [\"ext\", \"Host/src\", \"**/generated.jl\"]\n")
        inventory, units = planning_plan(root)
        @test [source.path for source in inventory.sources] == [driver, entry, kept]
        @test [unit.entry for unit in units] == [driver, entry]
        @test planning_unit(units, entry).expected == [entry, kept]
        planning_invariants(inventory, units)
    end
end

@testitem "read_config" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        @test JETSweep.read_config(root).file == ""
        @test isempty(JETSweep.read_config(root).exclude) && isempty(JETSweep.read_config(root).contexts)
        absent = joinpath(root, "absent.toml")
        @test_throws "ArgumentError: configuration file does not exist: $absent" begin
            JETSweep.read_config(root, absent)
        end
        @test_throws ArgumentError JETSweep.read_config(root, joinpath(root, ".JETSweep.toml"))

        planning_project(root, "tools/env")
        setup = planning_file(root, "tools/setup.jl")
        jetls = planning_file(root, "tools/jetls.toml")
        default = planning_file(root, ".JETSweep.toml", """
            exclude = ["vendor", "**/generated/*.jl"]

            [[context]]
            match = "tools/check.jl"
            project = "tools/env"
            setup = ["tools/setup.jl"]
            args = ["--fast", "two words"]
            env = { MODE = "analysis" }
            jetls_config = "tools/jetls.toml"

            [[context]]
            match = "**/*.jl"
            project = "tools/env/Project.toml"

            [[context]]
            match = "tools/*.jl"
            project = "tools/env/"
            """)
        config = JETSweep.read_config(root)
        @test config.file == default
        @test config.exclude == ["vendor", "**/generated/*.jl"]
        @test [rule.match for rule in config.contexts] == ["tools/check.jl", "**/*.jl", "tools/*.jl"]
        rule = first(config.contexts)
        @test rule.project == joinpath(root, "tools/env")
        @test rule.setup == [setup]
        @test rule.args == ["--fast", "two words"]
        @test rule.env == Dict("MODE" => "analysis")
        @test rule.jetls_config == jetls
        @test rule.keys == Set(["match", "project", "setup", "args", "env", "jetls_config"])
        @test config.contexts[2].project == joinpath(root, "tools/env")
        @test planning_overrides(config.contexts[2]) == PLANNING_NONE
        @test config.contexts[2].keys == Set(["match", "project"])
        @test config.contexts[3].project == joinpath(root, "tools/env")

        relocated = planning_file(root, "settings/sweep.toml",
                                  "[[context]]\nmatch = \"tools/check.jl\"\nsetup = [\"local.jl\"]\n")
        planning_file(root, "settings/local.jl")
        config = JETSweep.read_config(root, relocated)
        @test config.file == relocated
        @test only(config.contexts).setup == [joinpath(root, "settings/local.jl")]
        @test only(config.contexts).project == ""

        rule = "[[context]]\nmatch = \"a.jl\"\n"
        invalid = [
            "unknown = 1" => "unknown keys unknown",
            "exclude = \"vendor\"" => "`exclude` must be an array of strings",
            "exclude = [1]" => "`exclude` must be an array of strings",
            "[context]\nmatch = \"a.jl\"" => "`context` must be an array of tables",
            "context = 1" => "`context` must be an array of tables",
            "[[context]]\nproject = \"tools/env\"" => "each [[context]] needs a `match` glob",
            "[[context]]\nmatch = 1" => "each [[context]] needs a `match` glob",
            rule * "unknown = 1" => "unknown [[context]] keys unknown",
            rule * "project = \"tools\"" => "no Julia project at $(joinpath(root, "tools"))",
            rule * "project = \"absent\"" => "no Julia project at $(joinpath(root, "absent"))",
            rule * "project = 1" => "`project` must be a path",
            rule * "setup = [\"tools/absent.jl\"]" =>
                "setup file does not exist: $(joinpath(root, "tools/absent.jl"))",
            rule * "setup = \"tools/setup.jl\"" => "`setup` must be an array of strings",
            rule * "args = [1]" => "`args` must be an array of strings",
            rule * "env = { MODE = 1 }" => "`env` must be a table of strings",
            rule * "env = \"MODE\"" => "`env` must be a table of strings",
            rule * "jetls_config = \"tools/absent.toml\"" =>
                "JETLS configuration does not exist: $(joinpath(root, "tools/absent.toml"))",
            rule * "jetls_config = 1" => "`jetls_config` must be a path",
        ]
        for (content, message) in invalid
            write(default, content * "\n")
            @test_throws "ArgumentError: $default: $message" JETSweep.read_config(root)
        end
    end
end

@testitem "context rules apply to the units they match" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        environment = planning_project(root, "tools/env")
        check = planning_file(root, "tools/check.jl")
        other = planning_file(root, "tools/other.jl")
        loose = planning_file(root, "loose.jl")
        setup = planning_file(root, "tools/setup.jl")
        jetls = planning_file(root, "tools/jetls.toml")
        package = planning_package(root, "Pkg", "Pkg"; weakdeps=Dict("Dates" => PLANNING_DATES),
                                   extensions=Dict("PkgDatesExt" => "Dates"))
        entry = planning_file(package, "src/Pkg.jl", "module Pkg\ninclude(\"part.jl\")\nend\n")
        planning_file(package, "src/part.jl")
        extension = planning_file(package, "ext/PkgDatesExt.jl")
        test_file = planning_file(package, "test/runtests.jl")
        planning_file(root, ".JETSweep.toml", """
            exclude = ["vendor"]

            [[context]]
            match = "tools/check.jl"
            project = "tools/env"
            setup = ["tools/setup.jl"]
            args = ["--fast"]
            env = { MODE = "analysis" }
            jetls_config = "tools/jetls.toml"

            [[context]]
            match = "Pkg/test/**"
            project = "tools/env"
            args = ["--test"]

            [[context]]
            match = "Pkg/ext/*.jl"
            project = "tools/env"
            """)
        planning_file(root, "vendor/skipped.jl")
        inventory, units = planning_plan(root)

        @test !any(source -> occursin("vendor", source.path), inventory.sources)
        configured = planning_unit(units, check)
        @test configured.context == planning_context(environment, "")
        @test planning_overrides(configured.overrides) == ([setup], ["--fast"], Dict("MODE" => "analysis"), jetls)
        test_unit = planning_unit(units, test_file)
        @test test_unit.context == planning_context(environment, package, true)
        @test test_unit.overrides.args == ["--test"]
        @test test_unit.id == planning_unit(plan(inventory), test_file).id
        @test planning_unit(units, extension).context ==
              planning_context(environment, package, false, Dict("Dates" => PLANNING_DATES))
        for file in (setup, other, loose, entry)
            @test planning_overrides(planning_unit(units, file).overrides) == PLANNING_NONE
        end
        @test planning_unit(units, other).context == planning_context("", "")
        @test planning_unit(units, entry).context == planning_context(package, package)
        planning_invariants(inventory, units)

        planning_file(root, ".JETSweep.toml", "[[context]]\nmatch = \"*.jl\"\nargs = [\"--all\"]\n")
        _, units = planning_plan(root)
        @test planning_unit(units, loose).overrides.args == ["--all"]
        @test planning_unit(units, check).overrides.args == String[]
        # Tables matching the same unit combine: each key a later table sets overrides it.
        planning_file(root, ".JETSweep.toml", """
            [[context]]
            match = "*.jl"
            args = ["--all"]
            env = { A = "1", B = "1" }
            [[context]]
            match = "*.jl"
            env = { B = "2" }
            """)
        unit = planning_unit(last(planning_plan(root)), loose)
        @test unit.overrides.args == ["--all"]
        @test unit.overrides.env == Dict("A" => "1", "B" => "2")
    end
end

@testitem "setup applies to tests and scripts, and package analyses note it does not" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        setup = planning_file(root, "setup.jl")
        package = planning_package(root, "Pkg", "Pkg"; weakdeps=Dict("Dates" => PLANNING_DATES),
                                   extensions=Dict("PkgDatesExt" => "Dates"))
        entry = planning_file(package, "src/Pkg.jl", "module Pkg\nend\n")
        extension = planning_file(package, "ext/PkgDatesExt.jl")
        orphan = planning_file(package, "ext/Stray.jl")
        driver = planning_file(package, "test/runtests.jl")
        script = planning_file(package, "scripts/run.jl")
        config = planning_file(root, ".JETSweep.toml", """
            [[context]]
            match = "Pkg/**"
            setup = ["setup.jl"]
            args = ["--fast"]
            """)
        inventory, units = planning_plan(root)
        for file in (driver, script)
            @test planning_overrides(planning_unit(units, file).overrides) == ([setup], ["--fast"], Dict{String,String}(), "")
            @test isempty(planning_unit(units, file).notes)
        end
        for (file, kind) in ((entry, :package), (extension, :extension), (orphan, :orphan))
            unit = planning_unit(units, file)
            @test unit.kind === kind
            @test planning_overrides(unit.overrides) == (String[], ["--fast"], Dict{String,String}(), "")
            @test unit.notes == ["$config: setup does not apply to $kind analysis, which loads the package itself"]
        end
        planning_invariants(inventory, units)
    end
end

@testitem "scripts and tests get the packages they import without declaring them" setup=[Planning] begin
    mktempdir() do directory
        root = realpath(directory)
        sibling = planning_package(root, "Sibling", "Sibling")
        planning_file(sibling, "src/Sibling.jl", "module Sibling\nend\n")
        host = planning_package(root, "Host", "Host"; deps=Dict("Dates" => PLANNING_DATES, "Declared" => PLANNING_OTHER),
                                extras=Dict("Test" => PLANNING_TEST), targets=Dict("test" => ["Test"]))
        planning_file(host, "src/Host.jl", "module Host\nusing Dates\nend\n")
        test = planning_file(host, "test/runtests.jl", "using Test, Host, Declared\nusing Sibling\n")
        tool = planning_file(host, "scripts/tool.jl", "using Host, LinearAlgebra\nimport JSON\ninclude(\"helper.jl\")\n")
        planning_file(host, "scripts/helper.jl", "using Unknown.Inner: f\n")
        loose = planning_file(root, "loose.jl", "using Sibling\n")
        # Modules other files define, as `LOAD_PATH` finds them, are no packages to add.
        planning_file(root, "tools/Local.jl", "module Local\nend\n")
        runner = planning_file(root, "tools/run.jl", "push!(LOAD_PATH, @__DIR__)\nusing Local, Sibling\n")
        _, units = planning_plan(root)
        # Tests and the package's scripts share the test context, which gets the union.
        imports = Dict("Sibling" => sibling, "JSON" => "", "Unknown" => "")
        @test planning_unit(units, test).context.imports == imports
        @test planning_unit(units, tool).context == planning_unit(units, test).context
        @test planning_unit(units, loose).context.imports == Dict("Sibling" => sibling)
        @test planning_unit(units, runner).context.imports == Dict("Sibling" => sibling)
        # Package code that imports undeclared packages fails to load, as it would anyway.
        @test isempty(planning_unit(units, joinpath(host, "src", "Host.jl")).context.imports)
        @test isempty(planning_unit(units, joinpath(sibling, "src", "Sibling.jl")).context.imports)
        # Excluding a package leaves it out of the analysis, not of the workspace.
        inventory = discover(root; exclude=["Sibling"])
        units = plan(inventory)
        @test !any(unit -> startswith(unit.entry, sibling), units)
        @test planning_unit(units, loose).context.imports == Dict("Sibling" => sibling)
        @test planning_unit(units, test).context.imports == imports
        # A package the sweep analyzes wins its name from one it leaves out, as a fixture's copy;
        # two it analyzes leave the name to the registry.
        copy = planning_package(host, "test/fixtures/Sibling", "Sibling")
        planning_file(copy, "src/Sibling.jl", "module Sibling\nend\n")
        @test planning_unit(plan(discover(root; exclude=["fixtures"])), loose).context.imports == Dict("Sibling" => sibling)
        @test planning_unit(plan(discover(root)), loose).context.imports == Dict("Sibling" => "")
        # Of those it leaves out, one of the configuration's directory wins from one the
        # configuration excludes, as the full sweep has it.
        file = planning_file(root, ".JETSweep.toml", "exclude = [\"fixtures\"]\n")
        _, units = planning_plan(root)
        @test planning_unit(units, loose).context.imports == Dict("Sibling" => sibling)
        config = JETSweep.read_config(root)
        @test planning_unit(plan(discover(root; exclude=["Sibling"], config), config), loose).context.imports ==
              Dict("Sibling" => sibling)
        # A sweep of one of its directories finds the packages of the rest of it.
        @test planning_unit(last(planning_plan(host, file)), test).context.imports == imports
        @test planning_unit(plan(discover(host; exclude=["fixtures"])), test).context.imports ==
              merge(imports, Dict("Sibling" => copy))
    end
end
