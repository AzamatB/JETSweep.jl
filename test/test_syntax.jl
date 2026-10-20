using Test, JETSweep

const SyntaxInclude = JETSweep.Include

function syntax_write(root::String, relative::String, content::String)
    path = joinpath(root, relative)
    mkpath(dirname(path))
    write(path, content)
    return path
end

"Parse `code` as `source.jl` in a fresh directory: its directory, path and `Syntax`."
function syntax_parse(code::String; packages=Dict{String,JETSweep.Project}())
    mktempdir() do directory
        dir = realpath(directory)
        file = syntax_write(dir, "source.jl", code)
        return (; dir, file, syntax=JETSweep.parse_source(file, packages))
    end
end

"Include targets of `code`, relative to its directory; `\"\"` for a dynamic target."
function syntax_targets(code::String)
    parsed = syntax_parse(code)
    return [isempty(i.target) ? "" : relpath(i.target, parsed.dir) for i in parsed.syntax.includes]
end

"Write `files` under a fresh directory and call `f(prelude, dir)` for `drivers` and `target`."
function syntax_prelude(f, files::Pair{String,String}...;
                        drivers=["test/runtests.jl"], target="test/target.jl")
    mktempdir() do directory
        dir = realpath(directory)
        foreach(((path, code),) -> syntax_write(dir, path, code), files)
        return f(JETSweep.prelude(joinpath.(dir, drivers), joinpath(dir, target)), dir)
    end
end

syntax_callee(ex) = ex isa Symbol ? ex :
    Meta.isexpr(ex, (:call, :where, :(::), :curly, :(<:))) ? syntax_callee(first(ex.args)) : nothing

function syntax_names!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    if ex.head in (:toplevel, :block, :const, :global)
        foreach(arg -> syntax_names!(names, arg), ex.args)
    elseif ex.head in (:(=), :function, :abstract, :primitive)
        name = syntax_callee(first(ex.args))
        name === nothing || push!(names, name)
    elseif ex.head === :macro
        push!(names, Symbol("@", syntax_callee(first(ex.args))))
    elseif ex.head in (:struct, :module)
        push!(names, syntax_callee(ex.args[2]))
    elseif ex.head === :macrocall
        ex.args[1] === Symbol("@enum") ? push!(names, syntax_callee(ex.args[3])) :
            foreach(arg -> syntax_names!(names, arg), ex.args[2:end])
    end
    return names
end

"Names that the top-level statements of `text` define or assign."
syntax_names(text::String) = syntax_names!(Set{Symbol}(), Meta.parseall(text))

syntax_imports(text::String) = [ex for ex in Meta.parseall(text).args if Meta.isexpr(ex, (:using, :import))]

syntax_broken(ex) = ex isa Expr && (ex.head in (:error, :incomplete) || any(syntax_broken, ex.args))
syntax_parses(text::String) = !syntax_broken(Meta.parseall(text))

"Load `text` as a file of its own directory into a fresh module: the module, or the error."
function syntax_load(text::String)
    sandbox = Module(:SyntaxSandbox)
    mktempdir() do directory
        file = syntax_write(realpath(directory), "entry.jl", text)
        try
            Base.include(sandbox, file)
        catch err
            return err
        end
        return sandbox
    end
end

syntax_dynamic(file::String, line::Int) = "$file:$line: include target is only known at run time"

syntax_value(sandbox::Module, name::Symbol) = Base.invokelatest(getglobal, sandbox, name)
syntax_call(sandbox::Module, name::Symbol, args...) = Base.invokelatest(syntax_value(sandbox, name), args...)

@testset "parse_source resolves literal and path-call targets" begin
    parsed = syntax_parse(raw"""
        include("literal.jl")
        include("sub/../normalized.jl")
        include("/elsewhere/absolute.jl")
        include(joinpath(@__DIR__, "dir.jl"))
        include(joinpath(dirname(@__FILE__), "sub", "file.jl"))
        include(normpath(@__DIR__, "x", "..", "norm.jl"))
        include(dirname(@__DIR__) * "/parent.jl")
        include(abspath(@__DIR__, "abs.jl"))
        include("$(@__DIR__)/interpolated.jl")
        include("sub/$("name").jl")
        include(@__FILE__)
        """)
    dir = parsed.dir
    expected = [joinpath(dir, "literal.jl"), joinpath(dir, "normalized.jl"), "/elsewhere/absolute.jl",
                joinpath(dir, "dir.jl"), joinpath(dir, "sub", "file.jl"), joinpath(dir, "norm.jl"),
                joinpath(dirname(dir), "parent.jl"), joinpath(dir, "abs.jl"),
                joinpath(dir, "interpolated.jl"), joinpath(dir, "sub", "name.jl"), parsed.file]
    @test parsed.syntax.includes == [SyntaxInclude(target, line, true) for (line, target) in pairs(expected)]
    @test isempty(parsed.syntax.notes)
end

@testset "parse_source recognizes every include call form" begin
    parsed = syntax_parse("""
        include(identity, "mapped.jl")
        include(ex -> ex, joinpath(@__DIR__, "lambda_mapped.jl"))
        Base.include(@__MODULE__, "module.jl")
        Base.include(Main, joinpath(@__DIR__, "main.jl"))
        Base.include(identity, @__MODULE__, "mapped_module.jl")
        """)
    resolved(name, line) = SyntaxInclude(joinpath(parsed.dir, name), line, true)
    @test parsed.syntax.includes[1:4] == [resolved("mapped.jl", 1), resolved("lambda_mapped.jl", 2),
                                          resolved("module.jl", 3), resolved("main.jl", 4)]
    @test parsed.syntax.includes[5:end] == [resolved("mapped_module.jl", 5)]
    @test isempty(parsed.syntax.notes)

    # A method named `include` defines a function; only the call in its body includes.
    defined = syntax_parse("""
        function include(path)
            return Base.include(@__MODULE__, path)
        end
        """)
    @test defined.syntax.includes == [SyntaxInclude("", 2, false)]
    @test defined.syntax.notes == [syntax_dynamic(defined.file, 2)]
end

@testset "prelude keeps conditional imports that can load" begin
    # A whole-module import binds names not known statically; the test file may use any.
    driver = "using Test\n@static if VERSION >= v\"1.0\"\n    using Dates\nend\nfor f in ARGS\n    include(f)\nend\n"
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => "@test year(Date(2020, 1, 1)) == 2020\n") do text, dir
        @test occursin("using Dates", text)
        loaded = Module()
        Core.eval(loaded, :(include_string(@__MODULE__, $text)))
        @test Core.eval(loaded, :(year(Date(2020, 1, 1)))) == 2020
    end
    # A relative import of a module the prelude does not define would fail, inside a conditional too.
    hidden = "@eval module Helpers
h() = 1
end
@static if VERSION >= v\"1.0\"\n    using .Helpers: h\nend\n" *
             "for f in ARGS\n    include(f)\nend\n"
    syntax_prelude("test/runtests.jl" => hidden, "test/target.jl" => "h()\n") do text, dir
        @test !occursin("using .Helpers", text)
        @test Core.eval(Module(), :(include_string(@__MODULE__, $text); true))
    end
    shown = "module Helpers
h() = 1
end
@static if VERSION >= v\"1.0\"\n    using .Helpers: h\nend\n" *
            "for f in ARGS\n    include(f)\nend\n"
    syntax_prelude("test/runtests.jl" => shown, "test/target.jl" => "h()\n") do text, dir
        @test occursin("using .Helpers: h", text)
        loaded = Module()
        Core.eval(loaded, :(include_string(@__MODULE__, $text)))
        @test Core.eval(loaded, :(h())) == 1
    end
end

@testset "prelude follows the branch of a conditional that includes the test file" begin
    driver = """
        using Test
        if !isempty(ARGS)
            foreach(run_selected, ARGS)
        else
            helper() = 1
            if get(ENV, "TIER", "") == "1"
                tiered() = 2
                include("target.jl")
            end
            after() = 3
        end
        """
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => "helper() + tiered()\n") do text, dir
        @test occursin("helper() = 1", text) && occursin("tiered() = 2", text)
        @test !occursin("after() = 3", text) && !occursin("run_selected", text)
    end
end

@testset "prelude follows includes through pkgdir and pathof of the unit's package" begin
    mktempdir() do directory
        dir = realpath(directory)
        driver = syntax_write(dir, "test/runtests.jl", """
            include(joinpath(pkgdir(Dep), "test", "helpers.jl"))
            include(joinpath(dirname(pathof(Dep)), "..", "test", "more.jl"))
            for file in ARGS
                include(file)
            end
            """)
        syntax_write(dir, "test/helpers.jl", "helper() = 1\n")
        syntax_write(dir, "test/more.jl", "more() = 2\n")
        target = syntax_write(dir, "test/target.jl", "helper() + more()\n")
        dep = JETSweep.Project(dir, joinpath(dir, "Project.toml"), "Dep", "", joinpath(dir, "src", "Dep.jl"),
                               Dict{String,Dict{String,String}}())
        # Without the package, the first include ends what the prelude can know.
        @test !occursin("helper() = 1", JETSweep.prelude([driver], target))
        text = JETSweep.prelude([driver], target; packages=Dict("Dep" => dep))
        @test occursin("helper() = 1", text) && occursin("more() = 2", text)
    end
end

@testset "parse_source resolves pkgdir and pathof through the packages map" begin
    root = "/depot/packages/Dep"
    code = """
        include(joinpath(pkgdir(Dep), "bootstrap.jl"))
        include(pkgdir(Dep, "src", "part.jl"))
        include(joinpath(dirname(pathof(Dep)), "../test/object.jl"))
        include(Base.pathof(Dep))
        include(pkgdir(Unknown, "unknown.jl"))
        include(pkgdir(Dep, name))
        include(joinpath(dirname(pathof(Unknown)), "unknown.jl"))
        include(pathof(Dep, "extra"))
        """
    dep = JETSweep.Project(root, joinpath(root, "Project.toml"), "Dep", "", joinpath(root, "lib", "Main.jl"),
                           Dict{String,Dict{String,String}}())
    parsed = syntax_parse(code; packages=Dict("Dep" => dep))
    @test parsed.syntax.includes == [SyntaxInclude(joinpath(root, "bootstrap.jl"), 1, true),
                                     SyntaxInclude(joinpath(root, "src", "part.jl"), 2, true),
                                     SyntaxInclude(joinpath(root, "test", "object.jl"), 3, true),
                                     SyntaxInclude(dep.entry, 4, true),
                                     (SyntaxInclude("", line, true) for line in 5:8)...]
    @test parsed.syntax.notes == [syntax_dynamic(parsed.file, line) for line in 5:8]
    @test syntax_parse(code).syntax.includes == [SyntaxInclude("", line, true) for line in 1:8]
end

@testset "parse_source follows bindings to literal paths" begin
    @test syntax_targets(raw"""
        const SRC = joinpath(@__DIR__, "src")
        include(joinpath(SRC, "constant.jl"))
        file = "plain.jl"
        include(file)
        name = "interpolated"
        include("$name.jl")
        root = @__DIR__
        nested = joinpath(root, "nested")
        include(joinpath(nested, "chained.jl"))
        global declared = "global.jl"
        include(declared)
        begin
            blocked = "block.jl"
        end
        include(blocked)
        file = "rebound.jl"
        include(file)
        file = readline()
        include(file)
        """) == [joinpath("src", "constant.jl"), "plain.jl", "interpolated.jl",
                 joinpath("nested", "chained.jl"), "global.jl", "block.jl", "rebound.jl", ""]
end

@testset "parse_source scopes bindings" begin
    # Assignments inside conditionals and scopes neither leak nor survive as the outer value.
    @test syntax_targets("if flag\n    conditional = \"a.jl\"\nend\ninclude(conditional)\n") == [""]
    @test syntax_targets("p = \"a.jl\"\nif flag\n    p = \"b.jl\"\nend\ninclude(p)\n") == [""]
    @test syntax_targets("if flag\n    p = \"a.jl\"\nelse\n    p = \"b.jl\"\nend\ninclude(p)\n") == [""]
    @test syntax_targets("p = \"a.jl\"\nflag && (p = \"b.jl\")\ninclude(p)\n") == [""]
    @test syntax_targets("p = \"a.jl\"\np = flag ? \"b.jl\" : \"c.jl\"\ninclude(p)\n") == [""]
    @test syntax_targets("let\n    scoped = \"a.jl\"\nend\ninclude(scoped)\n") == [""]
    @test syntax_targets("function f()\n    local_path = \"a.jl\"\nend\ninclude(local_path)\n") == [""]
    @test syntax_targets("for i in 1:2\n    looped = \"a.jl\"\nend\ninclude(looped)\n") == [""]
    @test syntax_targets("try\n    tried = \"a.jl\"\ncatch\nend\ninclude(tried)\n") == [""]
    @test syntax_targets("let bound = \"a.jl\"\n    include(bound)\nend\ninclude(bound)\n") == ["a.jl", ""]
    # Outer bindings are visible in nested blocks and function bodies.
    @test syntax_targets("p = \"a.jl\"\nif flag\n    include(p)\nend\nf() = include(p)\n") == ["a.jl", "a.jl"]
    # A module has its own globals: its bindings stay inside, and it does not see the file's.
    @test syntax_targets("module M\ninner = \"a.jl\"\nend\ninclude(inner)\n") == [""]
    @test syntax_targets("p = \"a.jl\"\nmodule M\np = \"b.jl\"\ninclude(p)\nend\ninclude(p)\n") ==
          ["b.jl", "a.jl"]
    @test syntax_targets("p = \"a.jl\"\nmodule M\ninclude(p)\nend\n") == [""]
end

@testset "parse_source does not resolve shadowed or rebound names to stale bindings" begin
    # Arguments and iteration variables are locals that shadow the file's bindings.
    @test syntax_targets("p = \"a.jl\"\nload(p) = include(p)\n") == [""]
    @test syntax_targets("f = \"a.jl\"\n[include(f) for f in files]\n") == [""]
    # Updating and destructuring assignments rebind a name: the old value no longer holds.
    @test syntax_targets("p = \"a\"\np *= \".jl\"\ninclude(p)\n") in ([""], ["a.jl"])
    @test syntax_targets("p = \"a.jl\"\np, q = \"b.jl\", \"c.jl\"\ninclude(p)\n") in ([""], ["b.jl"])
end

@testset "parse_source records dynamic targets with a note" begin
    parsed = syntax_parse(raw"""
        include(ARGS[1])
        for f in files
            include(f)
        end
        include(abspath("relative.jl"))
        include(joinpath(@__DIR__, unknown))
        include("$(1).jl")
        include(ARGS[1]); include(ARGS[2])
        include("same.jl"); include("same.jl")
        """)
    dynamic = [1, 3, 5, 6, 7, 8]
    @test parsed.syntax.includes == [[SyntaxInclude("", line, true) for line in dynamic];
                                     SyntaxInclude(joinpath(parsed.dir, "same.jl"), 9, true)]
    @test parsed.syntax.notes == [syntax_dynamic(parsed.file, line) for line in dynamic]
end

@testset "parse_source marks includes in function bodies as not followed" begin
    parsed = syntax_parse("""
        function long_form()
            include("long.jl")
        end
        short_form() = include("short.jl")
        typed(x::T) where {T} = include("where.jl")
        anonymous = x -> include("anonymous.jl")
        long_anonymous = function ()
            include("long_anonymous.jl")
        end
        cd(@__DIR__) do
            include("do.jl")
        end
        macro loader()
            include("macro.jl")
        end
        @testset "suite" begin
            include("testset.jl")
        end
        @testset "inline" include("inline.jl")
        if flag
            include("if.jl")
        elseif other
            include("elseif.jl")
        else
            include("else.jl")
        end
        for i in 1:2
            include("for.jl")
        end
        while false
            include("while.jl")
        end
        let
            include("let.jl")
        end
        begin
            include("begin.jl")
        end
        try
            include("try.jl")
        catch
            include("catch.jl")
        end
        module Inner
        include("module.jl")
        function inner()
            include("module_function.jl")
        end
        end
        function outer()
            @testset "nested" begin
                include("function_testset.jl")
            end
        end
        """)
    unfollowed = ["long", "short", "where", "anonymous", "long_anonymous", "do", "macro", "module_function",
                  "function_testset"]
    followed = ["testset", "inline", "if", "elseif", "else", "for", "while", "let", "begin", "try", "catch",
                "module"]
    @test Dict(relpath(i.target, parsed.dir) => i.followed for i in parsed.syntax.includes) ==
          Dict(vcat(["$name.jl" => false for name in unfollowed], ["$name.jl" => true for name in followed]))
    @test isempty(parsed.syntax.notes)
end

@testset "parse_source ignores quoted code" begin
    parsed = syntax_parse("""
        expression = :(include("quoted.jl"))
        block = quote
            include("block.jl")
        end
        macro emit()
            return :(include(\$(QuoteNode(:path))))
        end
        constructed = Expr(:call, :include, "constructed.jl")
        """)
    @test isempty(parsed.syntax.includes)
    @test isempty(parsed.syntax.notes)
end

@testset "parse_source notes parse failures" begin
    parsed = syntax_parse("include(\"before.jl\")\nfunction broken(\n")
    @test parsed.syntax.includes == [SyntaxInclude(joinpath(parsed.dir, "before.jl"), 1, true)]
    @test startswith(only(parsed.syntax.notes), "$(parsed.file):2: cannot be parsed")

    mktempdir() do directory
        absent = joinpath(realpath(directory), "absent.jl")
        syntax = JETSweep.parse_source(absent)
        @test isempty(syntax.includes)
        @test startswith(only(syntax.notes), "$absent: cannot be read")
    end

    # The note describes the error; it does not carry the file's source.
    marker = "MARKER_FAR_ABOVE_THE_ERROR"
    distant = syntax_parse("# $marker\n" * "x = 1\n"^20 * "function broken(\n")
    note = only(distant.syntax.notes)
    @test startswith(note, "$(distant.file):22: cannot be parsed")
    @test !occursin(marker, note)
end

@testset "prelude keeps imports and definitions and drops other statements" begin
    driver = """
        using Test
        using Dates: Date, value as date_value
        import TOML
        import UUIDs as IDs
        println("driver side effect")
        @info "driver log"
        for i in 1:2
            loop_defined() = i
        end
        while false
            while_defined() = 1
        end
        @testset "inline" begin
            testset_defined() = 1
            @test true
        end
        function long_form(x)
            return x
        end
        short_form(x) = x
        typed(x::T) where {T} = x
        function declared end
        macro twice(ex)
            return esc(Expr(:block, ex, ex))
        end
        abstract type AbstractThing end
        struct Thing <: AbstractThing
            x::Int
        end
        mutable struct Box{T}
            value::T
        end
        primitive type Byte8 8 end
        @enum Color red green
        Base.@kwdef struct Options
            n::Int = 1
        end
        @kwdef struct Settings
            m::Int = 2
        end
        "A documented function."
        documented(x) = x
        "A documented struct."
        struct Documented end
        module Inner
        inner() = 1
        end
        Base.show(io::IO, ::Thing) = print(io, "thing")
        """
    # A module is kept where the target refers to it.
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => "@test Inner.inner() == 1\n") do text, dir
        @test syntax_parses(text)
        @test syntax_imports(text) == syntax_imports(driver)
        @test syntax_names(text) == Set([:long_form, :short_form, :typed, :declared, Symbol("@twice"),
                                         :AbstractThing, :Thing, :Box, :Byte8, :Color, :Options, :Settings,
                                         :documented, :Documented, :Inner])
        @test occursin("Base.show(io::IO, ::Thing)", text)
        @test !occursin("driver side effect", text)
        @test !occursin("driver log", text)
        @test !occursin("@testset", text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test syntax_call(sandbox, :Options).n == 1 && syntax_call(sandbox, :Settings).m == 2
            @test Base.invokelatest(repr, syntax_call(sandbox, :Thing, 1)) == "thing"
            @test syntax_call(syntax_value(sandbox, :Inner), :inner) == 1
        end
    end
end

@testset "prelude keeps the assignments the target and kept definitions refer to" begin
    driver = """
        using Test
        const USED_BY_TARGET = 1
        const UNUSED = 2
        const CHAIN_BASE = 3
        const CHAIN_TOP = CHAIN_BASE + 1
        const FOR_HELPER = 4
        helper() = FOR_HELPER
        const FOR_BODY = 5
        function body_helper()
            value = FOR_BODY
            return value
        end
        const DEEP_BASE = 6
        const DEEP = DEEP_BASE + 1
        deep_helper() = DEEP
        const FOR_PART = 7
        global TYPED::Int = 8
        counter = 0
        "Tolerance of the comparisons."
        const TOL = 1e-8
        const LOW, HIGH = 1, 2
        const ONLY_IN_TESTSET = 9
        @testset "inline" begin
            @test ONLY_IN_TESTSET == 9
        end
        const TEST_FILES = ["target.jl"]
        const TEST_ASKED = isempty(ARGS) ? split(get(ENV, "PKG_TESTS", ""), ",") : ARGS
        const TEST_RUN = isempty(TEST_ASKED) ? TEST_FILES : filter(in(TEST_ASKED), TEST_FILES)
        for file in TEST_RUN
            include(file)
        end
        # The target is included before these run.
        const AFTER = 10
        after_loop() = AFTER
        """
    target = """
        include("part.jl")
        @test USED_BY_TARGET == 1
        @test CHAIN_TOP == 4
        @test TYPED == 8
        @test 1 + TOL > 1
        @test LOW < HIGH
        counter += 1
        """
    files = ("test/runtests.jl" => driver, "test/target.jl" => target,
             "test/part.jl" => "@test FOR_PART == 7\n")
    @test mktempdir() do directory
        dir = realpath(directory)
        foreach(((path, code),) -> syntax_write(dir, path, code), files)
        JETSweep.prelude_modules([joinpath(dir, "test/runtests.jl")], joinpath(dir, "test/target.jl"))
    end == Set([:Test])
    syntax_prelude(files...) do text, dir
        names = syntax_names(text)
        @test syntax_parses(text)
        @test [:USED_BY_TARGET, :CHAIN_BASE, :CHAIN_TOP, :FOR_HELPER, :helper, :FOR_BODY, :body_helper,
               :DEEP_BASE, :DEEP, :deep_helper, :FOR_PART, :TYPED, :counter] ⊆ names
        @test isdisjoint(names, [:UNUSED, :ONLY_IN_TESTSET, :TEST_FILES, :TEST_ASKED, :TEST_RUN, :AFTER, :after_loop])
        @test :TOL in names
        @test !occursin("ARGS", text) && !occursin("ENV", text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test syntax_value(sandbox, :CHAIN_TOP) == 4
            @test syntax_call(sandbox, :body_helper) == 5 && syntax_call(sandbox, :deep_helper) == 7
            @test Base.invokelatest(isdefined, sandbox, :LOW) && Base.invokelatest(isdefined, sandbox, :HIGH)
        end
    end
end

@testset "prelude keeps the conditional definitions the target and kept definitions refer to" begin
    driver = """
        using Test
        const NEW = VERSION >= v"1.0"
        @static if NEW
            static_helper(x) = x + 1
        end
        if VERSION >= v"1.0"
            if_helper(x) = x + 2
        elseif VERSION >= v"0.7"
            if_helper(x) = x + 20
        else
            const IF_CONST = 1
        end
        uses_nested() = nested_helper()
        @static if VERSION >= v"1.0"
            @static if Sys.WORD_SIZE > 0
                "A nested helper."
                nested_helper() = 4
            end
        end
        struct Wrapped end
        if VERSION >= v"1.0"
            Base.length(::Wrapped) = 5
        end
        if VERSION >= v"1.0"
            unused_helper() = 6
        end
        if VERSION >= v"1.0"
            println("conditional side effect")
            mixed_helper() = 7
        end
        for file in ARGS
            include(file)
        end
        """
    target = "@test static_helper(1) + if_helper(1) + uses_nested() == 9\n@test mixed_helper() == 7\n"
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => target) do text, dir
        @test syntax_parses(text)
        @test occursin("@static if NEW", text) && occursin("const NEW", text)
        @test occursin("@eval begin\nif VERSION >= v\"1.0\"\n    if_helper(x) = x + 2", text)
        @test occursin("nested_helper() = 4", text) && occursin("Base.length(::Wrapped)", text)
        @test !occursin("unused_helper", text) && !occursin("mixed_helper", text) && !occursin("side effect", text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test syntax_call(sandbox, :static_helper, 1) == 2
            @test syntax_call(sandbox, :if_helper, 1) == 3
            @test syntax_call(sandbox, :uses_nested) == 4
            @test Base.invokelatest(length, syntax_call(sandbox, :Wrapped)) == 5
        end
    end
end

@testset "prelude follows the files the driver includes statically at top level" begin
    driver = """
        using Test
        include("helpers.jl")
        include(joinpath(@__DIR__, "sub", "nested.jl"))
        plain_helpers = joinpath(@__DIR__, "plain_helpers.jl")
        include(plain_helpers)
        const CONST_HELPERS = joinpath(@__DIR__, "const_helpers.jl")
        include(CONST_HELPERS)
        begin
            include("block_helpers.jl")
        end
        @testset "all" begin
            include("nested/runtests.jl")
            include("testset_only.jl")
        end
        skip_conditional() || include("conditional.jl")
        include("group.jl")
        include("target.jl")
        include("missing.jl")
        include("helpers.jl")
        function later()
            include("function_only.jl")
        end
        for file in ("loop_only.jl",)
            include(file)
        end
        """
    files = ("test/runtests.jl" => driver,
             "test/helpers.jl" => "from_helpers() = 1\ninclude(\"cycle.jl\")\n",
             "test/cycle.jl" => "include(\"helpers.jl\")\nfrom_cycle() = 1\n",
             "test/sub/nested.jl" => "from_nested() = 1\n",
             "test/plain_helpers.jl" => "from_plain_helpers() = 1\n",
             "test/const_helpers.jl" => "from_const_helpers() = 1\n",
             "test/block_helpers.jl" => "from_block() = 1\n",
             "test/group.jl" => "from_group() = 1\ninclude(\"target.jl\")\n",
             "test/target.jl" => "from_target() = 1\n",
             "test/nested/runtests.jl" => "from_nested_driver() = 1\n",
             "test/testset_only.jl" => "from_testset() = 1\n",
             "test/conditional.jl" => "from_conditional() = 1\n",
             "test/function_only.jl" => "from_function() = 1\n",
             "test/loop_only.jl" => "from_loop() = 1\n")
    syntax_prelude(files...) do text, dir
        names = syntax_names(text)
        @test syntax_parses(text)
        # A nested driver establishes context wherever it is included, as in a `@testset`;
        # other files included there are test files.
        @test [:from_helpers, :from_cycle, :from_nested, :from_plain_helpers, :from_block, :from_group,
               :from_nested_driver] ⊆ names
        @test isdisjoint(names, [:from_target, :from_function, :from_loop, :from_testset, :from_conditional])
        @test count("from_helpers()", text) == 1
        @test :from_const_helpers in names
    end

    # A binding rebound to a run-time value no longer names the file it first did.
    rebound = "helpers = \"helpers.jl\"\nhelpers = readline()\ninclude(helpers)\n"
    syntax_prelude("test/runtests.jl" => rebound, "test/helpers.jl" => "from_helpers() = 1\n",
                   "test/target.jl" => "") do text, dir
        @test !(:from_helpers in syntax_names(text))
    end
end

@testset "prelude relocates @__DIR__ and @__FILE__ to the original files" begin
    driver = """
        const DRIVER_DIR = @__DIR__
        const DRIVER_FILE = @__FILE__
        const QUALIFIED_DIR = Base.@__DIR__
        data_path(name) = joinpath(@__DIR__, "data", name)
        include("sub/helpers.jl")
        """
    helpers = """
        const HELPER_DIR = @__DIR__
        const HELPER_FILE = @__FILE__
        const DATA_DIR = joinpath(DRIVER_DIR, "data")
        """
    target = "DRIVER_FILE, QUALIFIED_DIR, data_path, HELPER_DIR, HELPER_FILE, DATA_DIR\n"
    files = ("test/runtests.jl" => driver, "test/sub/helpers.jl" => helpers, "test/target.jl" => target)
    syntax_prelude(files...) do text, dir
        tests = joinpath(dir, "test")
        @test syntax_parses(text)
        @test !occursin("@__DIR__", text) && !occursin("@__FILE__", text)
        # Analysis always evaluates `@eval`, which the generated file needs for its pure
        # assignments, since concretization patterns cannot apply to it.
        @test occursin("@eval begin\nconst DATA_DIR = joinpath(DRIVER_DIR, \"data\")\nend", text)
        @test !occursin("@eval data_path", text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test syntax_value(sandbox, :DRIVER_DIR) == tests
            @test syntax_value(sandbox, :DRIVER_FILE) == joinpath(tests, "runtests.jl")
            @test syntax_value(sandbox, :QUALIFIED_DIR) == tests
            @test syntax_call(sandbox, :data_path, "x.csv") == joinpath(tests, "data", "x.csv")
            @test syntax_value(sandbox, :HELPER_DIR) == joinpath(tests, "sub")
            @test syntax_value(sandbox, :HELPER_FILE) == joinpath(tests, "sub", "helpers.jl")
            @test syntax_value(sandbox, :DATA_DIR) == joinpath(tests, "data")
        end
    end

    # Relative includes inside kept statements still resolve against the driver's directory.
    driver = "module TestHelpers\ninclude(\"module_helpers.jl\")\nend\nusing .TestHelpers\n"
    files = ("test/runtests.jl" => driver, "test/target.jl" => "module_helper()\n",
             "test/module_helpers.jl" => "export module_helper\nmodule_helper() = 42\n")
    syntax_prelude(files...) do text, dir
        sandbox = syntax_load(text)
        @test sandbox isa Module
        sandbox isa Module && @test syntax_call(syntax_value(sandbox, :TestHelpers), :module_helper) == 42
    end
end

@testset "prelude output loads as the definitions it was made from" begin
    driver = raw"""
        interpolated(x) = "v=$x, w=$(x + 1)"
        dollar() = "\$"
        ends(a) = a[begin] + a[end]
        separators() = r"[,\s]+"
        odd() = var"odd name"
        const var"odd name" = 3
        keywords(x; k=1) = x + k
        """
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => "") do text, dir
        @test syntax_parses(text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test syntax_call(sandbox, :interpolated, 1) == "v=1, w=2"
            @test syntax_call(sandbox, :dollar) == "\$"
            @test syntax_call(sandbox, :ends, [1, 2, 3]) == 4
            @test split("a, b", syntax_call(sandbox, :separators)) == ["a", "b"]
            @test syntax_call(sandbox, :odd) == 3
            @test syntax_call(sandbox, :keywords, 1) == 2
        end
    end

    # Quoted code in a kept definition stays quoted code.
    driver = raw"""
        macro twice(ex)
            return esc(:($ex; $ex))
        end
        quoted() = :(a + b)
        block() = quote
            x = 1
        end
        """
    syntax_prelude("test/runtests.jl" => driver, "test/target.jl" => "") do text, dir
        @test syntax_parses(text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            @test Core.eval(sandbox, :(let n = Ref(0); @twice(n[] += 1); n[]; end)) == 2
            @test syntax_call(sandbox, :quoted) == :(a + b)
            @test Meta.isexpr(syntax_call(sandbox, :block), :block)
        end
    end
end

@testset "prelude of a Godela-style driver keeps the context and drops the selection" begin
    driver = raw"""
        import UUIDs
        UUIDs.uuid4()

        using Test
        using Dates

        const DT = Dates

        DT.now()

        # Files a run takes, all by default or those named in ARGS or SOMEPKG_TESTS.
        const TEST_FILES = ["runtests.jl", "test_alpha.jl", "test_beta.jl"]
        const TEST_ASKED = isempty(ARGS) ? split(get(ENV, "SOMEPKG_TESTS", ""), r"[,\s]+"; keepempty=false) : ARGS
        for f in TEST_ASKED
            f in TEST_FILES || error("no test file $(repr(f)); the files are ", join(TEST_FILES, ", "))
        end
        const TEST_RUN = isempty(TEST_ASKED) ? TEST_FILES : filter(in(TEST_ASKED), TEST_FILES)

        const ORIGINAL_GUARD_FILES = ("test_guards.jl",)
        function _include_suite_test(file)
            file in ORIGINAL_GUARD_FILES && return nothing
            include(joinpath(@__DIR__, file))
            return nothing
        end

        "Days from `a` to `b`, as the tests count them."
        days_between(a, b) = DT.value(b - a)

        @testset "SomePkg.jl" begin
            "runtests.jl" in TEST_RUN && @testset "runtests.jl" begin
                @test days_between(DT.Date(2026), DT.Date(2026)) == 0
            end
            for file in TEST_RUN
                file == "runtests.jl" || _include_suite_test(file)
            end
        end
        """
    target = """
        @testset "alpha" begin
            @test days_between(DT.Date(2026, 1, 1), DT.Date(2026, 1, 2)) == 1
        end
        """
    files = ("test/runtests.jl" => driver, "test/test_alpha.jl" => target)
    syntax_prelude(files...; target="test/test_alpha.jl") do text, dir
        names = syntax_names(text)
        @test syntax_parses(text)
        @test syntax_imports(text) == syntax_imports(driver)
        @test names == Set([:DT, :ORIGINAL_GUARD_FILES, :_include_suite_test, :days_between])
        @test !occursin("uuid4", text) && !occursin("now()", text)
        @test !occursin("ARGS", text) && !occursin("ENV", text)
        sandbox = syntax_load(text)
        @test sandbox isa Module
        if sandbox isa Module
            DT = syntax_value(sandbox, :DT)
            @test nameof(DT) === :Dates
            @test syntax_call(sandbox, :days_between, DT.Date(2026, 1, 1), DT.Date(2026, 1, 3)) == 2
        end
    end
end

"Concretization patterns of `code` written as `file.jl`."
function syntax_patterns(code::String)
    mktempdir() do directory
        return JETSweep.concretization_patterns(syntax_write(realpath(directory), "file.jl", code))
    end
end

@testset "concretization_patterns selects statements free of side effects" begin
    code = """
        using LinearAlgebra
        import Statistics as Stats
        const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
        const POLY = [(0.0, 0.0), (1.0, 0.5)]
        const PORT = length(POLY) + 1
        const NAMES = (imin = "inlet", imax = "outlet")
        const ALIAS = LinearAlgebra
        const STATS = Stats.mean
        const LOW, HIGH = 1, 2
        const SEED = rand()
        const AFTER = SEED + 1
        const CALL = user_function(1)
        value = 3
        value += 1
        DIR = @__DIR__
        if !@isdefined(GUARDED)
            const GUARDED = LinearAlgebra
        end
        if !@isdefined(SIDE)
            const SIDE = rand()
        end
        if flag
            const FLAGGED = 1
        end
        module Inner
        const INNER = 1 + 2
        end
        const DATA_ = 4
        const STALE = value * 2
        f(x) = x + 1
        """
    @test syntax_patterns(code) == [
        "const ROOT = normpath(joinpath(@__DIR__, \"..\", \"..\"))", "const POLY = [(0.0, 0.0), (1.0, 0.5)]",
        "const PORT = length(POLY) + 1", "const NAMES = (imin = \"inlet\", imax = \"outlet\")",
        "const ALIAS = LinearAlgebra", "const STATS = Stats.mean", "const LOW, HIGH = 1, 2", "value = 3",
        "DIR = @__DIR__", "if !@isdefined(GUARDED)\n    const GUARDED = LinearAlgebra\nend", "const INNER = 1 + 2",
        "const DATA_ = 4"]
    for pattern in syntax_patterns(code)
        @test Meta.parse(pattern) isa Expr
    end
end

@testset "concretization_patterns evaluates run-dependent values only where analysis needs them" begin
    code = """
        outdir = ARGS[1]
        mesh, case = ARGS
        const KEY = ENV["HOME"]
        const LEVEL = isempty(ARGS) ? 1 : 2
        level_method(::Val{LEVEL}) = 1
        const ASKED = isempty(ARGS) ? split(get(ENV, "TESTS", ""), ","; keepempty=false) : ARGS
        # JETLS evaluates a condition to define the closures in its branches, and then
        # does not define those in the branch not taken, unless the whole statement is evaluated.
        const RUN = isempty(ASKED) ? FILES : filter(f -> f in ASKED, FILES)
        const PICKED = isempty(ASKED) ? ["a"] : filter(f -> f in ASKED, ["a"])
        # Unless what it evaluates besides the conditions depends on the run.
        const LABELS = isempty(ASKED) ? sort([f for f in readdir("fields")]) : ASKED
        const SKIP = get(ENV, "SKIP", "")
        skipped() = SKIP
        # JETLS evaluates the condition that chooses what to import.
        const MEASURE = get(ARGS, 1, "") == "--measure"
        if MEASURE
            using Statistics
        end
        """
    @test syntax_patterns(code) == ["const LEVEL = isempty(ARGS) ? 1 : 2",
        "const ASKED = isempty(ARGS) ? split(get(ENV, \"TESTS\", \"\"), \",\"; keepempty=false) : ARGS",
        "const PICKED = isempty(ASKED) ? [\"a\"] : filter(f -> f in ASKED, [\"a\"])",
        "const MEASURE = get(ARGS, 1, \"\") == \"--measure\"", "if MEASURE\n    using Statistics\nend"]
end

@testset "concretization_patterns follows what JETLS outlines, includes and imports" begin
    # The worker outlines expressions of calls and control flow, so the closures in their
    # branches need no evaluated conditions; one that assigns is not outlined.
    @test JETSweep._outlined(:(lock === nothing || atexit(() -> close(lock))))
    @test JETSweep._outlined(:(ready || foreach(function (x)::Nothing; println(x); end, xs)))
    # Lowering evaluates the types of a closure's parameters where it stands.
    @test !JETSweep._outlined(:(ready || foreach((x::Row) -> x, xs)))
    @test !JETSweep._outlined(:(ready || foreach((x; y::Row=Row()) -> x, xs)))
    @test !JETSweep._outlined(:(ready || foreach((x, y::Row=Row()) -> x, xs)))
    @test !JETSweep._outlined(:(ready || foreach(xs) do x::Row; x; end))
    @test !JETSweep._outlined(:(ready || foreach(function (x::T) where {T}; x; end, xs)))
    @test JETSweep._outlined(:(ready || foreach((x=Row()) -> x, xs)))
    # A conditional of tests binds nothing either, unless a branch does at its own level.
    @test JETSweep._outlined(:(if get(ENV, "X", "") == "1"; f(); @testset "t" begin; y = 1; foreach(x -> x + y, 1:2); end; end))
    @test !JETSweep._outlined(:(if get(ENV, "X", "") == "1"; y = 1; @testset "t" begin; foreach(x -> x, 1:2); end; end))
    @test !JETSweep._outlined(:(if ready; @testset "t" include("t.jl"); foreach(x -> x, 1:2); end))
    @test !JETSweep._outlined(:(if ready; @time foreach(x -> x, 1:2); end))
    @test syntax_patterns("const ON = get(ENV, \"X\", \"\") == \"1\"\nif ON\n    @testset \"t\" begin\n        foreach(x -> x, 1:2)\n    end\nend\n") ==
          String[]
    # Loop and `let` bodies are local scopes already, unless they import.
    @test JETSweep._outlined(:(for (name, entries) in deps; if haskey(m, name); all(e -> e, entries); end; end))
    @test JETSweep._outlined(:(let r = slow(); if r > 0; g(x) = x + 1; end; end))
    @test !JETSweep._outlined(:(for x in xs; foreach(y -> y, x); end))
    @test !JETSweep._outlined(:(for m in ms; using Test; ready && map(x -> x, m); end))
    @test !JETSweep._outlined(:(for f in fs; ready && include(f); map(x -> x, f); end))
    @test syntax_patterns("const ITEMS = readdir(ARGS[1])\nfor item in ITEMS\n    isdir(item) && foreach(println, filter(x -> x, item))\nend\n") ==
          String[]
    # A function a loop defines is a closure, so its loop needs no values.
    @test syntax_patterns("const ITEMS = readdir(ARGS[1])\nfor item in ITEMS\n    show_item() = println(item)\nend\n") ==
          String[]
    @test !JETSweep._outlined(:(x = cond ? 1 : map(y -> y, z)))
    @test !JETSweep._outlined(:(ready && include(f)))
    # A generator's ranges stand outside its closure, as do interpolations into quotes.
    @test JETSweep._outlined(:(ready && [a.b for a in items] == [1]))
    @test !JETSweep._outlined(:(ready && [a for a in (items = f(); items)] == [1]))
    @test !JETSweep._outlined(:(ready && g(:(h($(y = 1)))) && map(x -> x, z)))
    @test syntax_patterns("const LOCK = isempty(ARGS) ? nothing : 1\nLOCK === nothing || atexit(() -> close(LOCK))\n") ==
          String[]
    @test syntax_patterns("const PICK = isempty(ARGS) ? 1 : 2\nconst F = PICK > 1 ? map(x -> x, 1:2) : 0\n") ==
          ["const PICK = isempty(ARGS) ? 1 : 2", "const F = PICK > 1 ? map(x -> x, 1:2) : 0"]
    # JETLS evaluates `include_string` calls as it does `eval` calls, so what they need is.
    code = """
        const SNAPSHOT = snapshot(joinpath(@__DIR__, "helper.jl"))
        Base.include_string(@__MODULE__, String(copy(SNAPSHOT.bytes)), SNAPSHOT.path)
        using .Helper
        """
    @test syntax_patterns(code) == ["const SNAPSHOT = snapshot(joinpath(@__DIR__, \"helper.jl\"))"]
    # Wherever the call stands, and through what command literals interpolate.
    code = """
        const SOURCE = joinpath(get(ENV, "SOURCE_ROOT", @__DIR__), "Source.jl")
        let code = read(`git -C \$SOURCE show HEAD:helper.jl`, String)
            include_string(@__MODULE__, code, "helper.jl")
        end
        """
    @test syntax_patterns(code) == ["const SOURCE = joinpath(get(ENV, \"SOURCE_ROOT\", @__DIR__), \"Source.jl\")"]
    @test JETSweep._symbols(Meta.parse("`a \$b \$(c.d):e`")) == Set([:b, :c, :d])
    # `import A.f` may bind a function, so only whole modules count.
    @test JETSweep._modules(:(using A.B, C)) == Set([:B, :C])
    @test JETSweep._modules(:(import D, E.f, F as G, H.i as j)) == Set([:D, :G])
    # Modules that run before the file, as a driver's prelude imports, are known.
    mktempdir() do directory
        file = syntax_write(realpath(directory), "file.jl", "const DATA = joinpath(pkgdir(Pkg1), \"data\")\n")
        @test JETSweep.concretization_patterns(file) == String[]
        @test JETSweep.concretization_patterns(file; modules=Set([:Pkg1])) == ["const DATA = joinpath(pkgdir(Pkg1), \"data\")"]
    end
end

@testset "concretization_patterns needs only what JETLS evaluates, where it does" begin
    # Default values and argument names are not evaluated when a method is defined, nor is
    # the quoted code `@eval` defines, except what it interpolates.
    @test syntax_patterns("outdir = ARGS[1]\nwrite_to(x; dir=outdir) = x\n") == String[]
    @test syntax_patterns("const NAME = ARGS[1]\n@eval named() = NAME\n") == String[]
    @test syntax_patterns("const LEVEL = length(ARGS)\n@eval level() = \$LEVEL\n") == ["const LEVEL = length(ARGS)"]
    # Code `eval` runs at top level reads what it reads, not what its methods do.
    @test syntax_patterns("const X = length(ARGS)\n@eval const Y = X + 1\n") == ["const X = length(ARGS)"]
    @test syntax_patterns("out = open(\"run.log\", \"w\")\n@eval log(out, msg) = println(out, msg)\n") == String[]
    # An earlier binding counts where a conditional may leave the name as it was.
    code = """
        file = isempty(ARGS) ? "default.jl" : ARGS[1]
        if Sys.iswindows()
            file = "windows.jl"
        end
        include(file)
        """
    @test syntax_patterns(code) == ["file = isempty(ARGS) ? \"default.jl\" : ARGS[1]",
                                    "if Sys.iswindows()\n    file = \"windows.jl\"\nend"]
    # The binding that reaches the need is evaluated, not an earlier one.
    code = """
        file = ARGS[1]
        file = isempty(ARGS) ? "default.jl" : ARGS[1]
        include(file)
        """
    @test syntax_patterns(code) == ["file = isempty(ARGS) ? \"default.jl\" : ARGS[1]"]
    # JETLS evaluates type aliases itself, and so what they read.
    @test syntax_patterns("const N = length(ARGS)\nconst Row = NTuple{N,Int}\n") == ["const N = length(ARGS)"]
    # Local variables do not hide Base's functions; functions with side effects are not pure
    # arguments of pure ones.
    code = """
        smallest(x) = (min = minimum(x); min)
        const M = min(1, 2)
        const REMOVED = map(rm, ["a", "b"])
        const RM = Base.rm
        """
    @test syntax_patterns(code) == ["const M = min(1, 2)"]
end

@testset "concretization_patterns forgets values that other code may change" begin
    code = """
        errs = Float64[]
        for i in 1:3
            push!(errs, i)
        end
        ratio = errs[1] / errs[2]
        const SEEN = Int[]
        note(h) = push!(SEEN, h)
        sparse = first(SEEN)
        const TABLE = Dict{String,Int}()
        TABLE["a"] = 1
        const COUNT = length(TABLE)
        fld = open(read, "data.bin")
        mesh = joinpath("meshes", "mesh_\$(fld.yaw).jls")
        range(a, b) = (println("range"); a:b)
        const R = range(1, 3)
        const S = Base.range(1, 3)
        helper() = 1
        const H = helper
        const MAPPED = map(helper, 1:3)
        const W = map(x -> x + 1, 1:3)
        # Globals of modules the analyzed code defines may be left unevaluated.
        using .Local
        const FROM_LOCAL = Local.ROOT
        """
    @test syntax_patterns(code) == ["errs = Float64[]", "const SEEN = Int[]", "const TABLE = Dict{String,Int}()",
                                    "const S = Base.range(1, 3)", "const W = map(x -> x + 1, 1:3)"]
    # Reading files has no side effects, but the files may not exist where analysis runs, so
    # their contents are evaluated only where needed.
    read_only = """
        const MANIFEST = read(joinpath(@__DIR__, "manifest.json"), String)
        const AST = Meta.parseall(MANIFEST)
        const SEALED = !occursin("sha256:" * "0"^64, MANIFEST)
        Core.eval(@__MODULE__, AST)
        """
    @test syntax_patterns(read_only) == ["const MANIFEST = read(joinpath(@__DIR__, \"manifest.json\"), String)",
                                         "const AST = Meta.parseall(MANIFEST)"]
end

@testset "concretization_patterns takes blocks and conditionals whole, as JETLS matches them" begin
    code = """
        begin
            const ROOT = dirname(@__DIR__)
            names = collect(1:3)
        end
        begin
            const A = 1
            y = rand()
        end
        const DATA = joinpath(ROOT, "data")
        const AFTER_A = A + 1
        if Sys.iswindows()
            const EXT = ".exe"
        else
            const EXT = ""
        end
        const BIN = "tool" * EXT
        if Sys.iswindows()
            const ONLY_WINDOWS = 1
        end
        const READ_ONLY_WINDOWS = ONLY_WINDOWS + 1
        """
    @test syntax_patterns(code) == [
        "begin\n    const ROOT = dirname(@__DIR__)\n    names = collect(1:3)\nend", "const DATA = joinpath(ROOT, \"data\")",
        "if Sys.iswindows()\n    const EXT = \".exe\"\nelse\n    const EXT = \"\"\nend", "const BIN = \"tool\" * EXT",
        "if Sys.iswindows()\n    const ONLY_WINDOWS = 1\nend", "const READ_ONLY_WINDOWS = ONLY_WINDOWS + 1"]
end

@testset "concretization_patterns leaves out patterns that would match other statements" begin
    # MacroTools matches structurally, with names such as `x_` and `@__DIR__` as wildcards.
    code = """
        x = rand(3)
        n = length(x)
        x = [1.0, 2.0]
        n = length(x)
        const D = @__DIR__
        const D = @something(nothing, 1)
        A_ = 1
        const B = A_ + 1
        const B = rand() + 1
        const ANY_ = 4
        const LAST = 4
        """
    # `const ANY_ = 4` matches `const LAST = 4` too, which is evaluated anyway.
    @test syntax_patterns(code) == ["x = [1.0, 2.0]", "A_ = 1", "const ANY_ = 4", "const LAST = 4"]
    @test JETSweep._may_match(:(const D = @__DIR__), :(const D = @anything(1, 2)))
    @test JETSweep._may_match(:(const X_ = 4), :(const Y = 4))
    @test !JETSweep._may_match(:(const X = 4), :(const Y = 4))
    @test JETSweep._may_match(Expr(:block, :(a = 1)), :(a = 1))
end

@testset "concretization_patterns of a test driver evaluates its file selection" begin
    driver = """
        const FILES = ["test_a.jl", "test_b.jl"]
        const ASKED = isempty(ARGS) ? split(get(ENV, "TESTS", ""), ","; keepempty = false) : ARGS
        const RUN = isempty(ASKED) ? FILES : filter(in(ASKED), FILES)
        const UNRELATED = rand()
        helper() = 1
        @testset "suite" begin
            for file in RUN
                include(file)
            end
        end
        """
    selected = ["const FILES = [\"test_a.jl\", \"test_b.jl\"]",
        "const ASKED = isempty(ARGS) ? split(get(ENV, \"TESTS\", \"\"), \",\"; keepempty = false) : ARGS",
        "const RUN = isempty(ASKED) ? FILES : filter(in(ASKED), FILES)"]
    @test syntax_patterns(driver) == selected
    # What `include` and `eval` calls need is evaluated even when not pure, since JETLS
    # evaluates those calls; not what other evaluated code needs.
    listing = "const FILES = list_tests()\nfor file in FILES\n    include(file)\nend\n"
    @test syntax_patterns(listing) == ["const FILES = list_tests()"]
    generated = "const BODY = make_body()\nCore.eval(@__MODULE__, Expr(:function, :(f()), BODY))\n"
    @test syntax_patterns(generated) == ["const BODY = make_body()"]
    @test syntax_patterns("const N = compute()\ng(::Val{N}) = 1\n") == String[]
    # Includes inside functions run only when called, so nothing selects them statically.
    @test syntax_patterns("const FILES = list_tests()\nrun(f) = include(f)\nforeach(run, FILES)\n") == String[]
end

@testset "includes resolve through path constants other files define" begin
    mktempdir() do directory
        root = realpath(directory)
        bootstrap = syntax_write(root, "lib/bootstrap.jl", "const LIBDIR = @__DIR__\nconst DATA = joinpath(dirname(LIBDIR), \"data\")\n")
        lib = syntax_write(root, "lib/lib.jl", "include(\"bootstrap.jl\")\n")
        census = syntax_write(root, "lib/census.jl", "")
        script = syntax_write(root, "dev/script.jl",
                              "include(joinpath(dirname(@__DIR__), \"lib\", \"lib.jl\"))\ninclude(joinpath(LIBDIR, \"census.jl\"))\n")
        inventory = discover(root)
        syntax = JETSweep.source_syntax(inventory)
        @test syntax[bootstrap].bindings == Dict(:LIBDIR => dirname(bootstrap), :DATA => joinpath(root, "data"))
        @test [include.target for include in syntax[script].includes] == [lib, census]
        @test isempty(syntax[script].notes)
    end
end

@testset "parse_source records the packages imports load" begin
    parsed = syntax_parse("""
        using A, B.C
        import D as E
        import F: g, h as k
        using .Local, ..Parent
        quoted() = :(using Q)
        @eval using Generated
        if flag
            using Conditional
        end
        """)
    @test parsed.syntax.imports == ["A", "B", "D", "F", "Generated", "Conditional"]
end
