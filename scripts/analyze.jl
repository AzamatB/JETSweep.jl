# JETSweep analysis worker: analyzes one unit and writes its result.
#
#     julia --project=ENVIRONMENT analyze.jl REQUEST.toml RESULT.toml
#
# ENVIRONMENT is the unit's prepared analysis environment. It provides JETLS with its
# Revise-based package analysis enabled, and the unit's own dependencies, resolved together
# so that both use the same version of every shared package. The worker loads nothing else.
module JETSweepWorker

using JETLS, TOML

const LS = Base.require(JETLS, :JETLSCore)

# JET outlines a test expression into a thunk when it defines an anonymous function in a
# conditional branch, as in `@test isnothing(x) || all(y -> y > 0, x)`, because realizing a
# closure there concretely executes the conditions before it: the test itself, in JET's
# interpreter. Generators and comprehensions define closures too, so treat them alike;
# otherwise `@test r.ok && [a.b for a in r.items] == [1]` runs whatever computes `r`.
# `JETSweep._outlined` mirrors these rules.
Core.eval(LS.JET, quote
    # A generator's ranges are evaluated where it stands, so it can be outlined only if they can.
    function outlinable_generator(@nospecialize(ex))
        isexpr(ex, (:comprehension, :flatten), 1) && return outlinable_generator(only(ex.args))
        isexpr(ex, :typed_comprehension, 2) &&
            return is_test_expression_thunk_safe(first(ex.args)) && outlinable_generator(last(ex.args))
        isexpr(ex, :generator) || return false
        for spec in ex.args[2:end]
            specs = isexpr(spec, :filter) ? spec.args[2:end] : Any[spec]
            all(s -> isexpr(s, :(=), 2) && is_test_expression_thunk_safe(last(s.args)), specs) || return false
        end
        return true
    end
    function is_anonymous_test_function(@nospecialize(ex))
        (isexpr(ex, :->, 2) || outlinable_generator(ex)) && return true
        isexpr(ex, :function, 2) || return false
        sig = first(ex.args)
        while isexpr(sig, (:(::), :where)) && !isempty(sig.args)
            sig = first(sig.args)
        end
        return isexpr(sig, :tuple)
    end
end)
"""
Whether `ex` must stay at top level: it includes or evaluates code, which JET follows only
there, or interpolates into quoted code, which runs where the quote stands.
"""
stays(ex) = ex isa Expr && (ex.head === :$ ||
    (ex.head === :call && !isempty(ex.args) && LS.JET.isexpr(first(ex.args), :.) ?
        last(first(ex.args).args) in (QuoteNode(:include), QuoteNode(:eval), QuoteNode(:include_string)) :
        ex.head === :call && first(ex.args) in (:include, :eval, :include_string)) ||
    (ex.head === :macrocall && macro_name(ex) === Symbol("@eval")) || any(stays, ex.args))

"Whether parameters declare types, which lowering evaluates where a closure stands."
typed(p) = p isa Expr && (p.head in (:(::), :where) ||
    (p.head in (:tuple, :block, :parameters, :kw, :(=), :...) && any(typed, p.head in (:kw, :(=)) ? p.args[1:1] : p.args)))

"Whether `ex` defines a closure with typed parameters or a `where` clause."
function typed_closure(ex)
    ex isa Expr || return false
    ex.head === :-> && typed(first(ex.args)) && return true
    if ex.head === :function && length(ex.args) == 2
        signature = first(ex.args)
        Meta.isexpr(signature, :(::), 2) && (signature = first(signature.args))
        (Meta.isexpr(signature, :where) || (Meta.isexpr(signature, :tuple) && typed(signature))) && return true
    end
    return any(typed_closure, ex.args)
end

"""
Whether `ex` defines a function, anonymous or local, under control flow: in a branch, whose
condition JET would evaluate to define it, or, with `nested`, in a loop too, whose control
flow and captured values JET may run to define it there.
"""
function controlled_function(ex, controlled::Bool=false; nested::Bool=false)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return false
    (ex.head in (:->, :function, :generator) || (ex.head === :(=) && signature(first(ex.args)))) && return controlled
    if ex.head in (:if, :elseif, :&&, :||)
        return controlled_function(first(ex.args), controlled; nested) ||
            any(arg -> controlled_function(arg, true; nested), ex.args[2:end])
    end
    nested && ex.head in (:for, :while) && return any(arg -> controlled_function(arg, true; nested), ex.args)
    return any(arg -> controlled_function(arg, controlled; nested), ex.args)
end
signature(ex) = ex isa Expr && (ex.head === :call || (ex.head in (:where, :(::)) && signature(first(ex.args))))
imports(ex) = ex isa Expr && !(ex.head in (:quote, :inert)) && (ex.head in (:using, :import) || any(imports, ex.args))

"""
The name of the function a method definition's signature `sig` extends: a symbol for a
function of its own, an expression for a qualified or callable one, `nothing` for an
anonymous function.
"""
function method_name(sig)
    sig isa Symbol && return sig
    while Meta.isexpr(sig, :where) || Meta.isexpr(sig, :(::), 2)
        sig = first(sig.args)
    end
    return Meta.isexpr(sig, :call) && !isempty(sig.args) ? first(sig.args) : nothing
end
"The name of the function `ex` defines a method of, as `method_name` gives it, if `ex` is a method definition."
definition_name(ex) = ex isa Expr && (ex.head === :function || (ex.head === :(=) && signature(first(ex.args)))) ?
    method_name(first(ex.args)) : nothing

"The names an assignment's left-hand side binds, typed or destructured."
assignees(lhs) = lhs isa Symbol ? Symbol[lhs] : Meta.isexpr(lhs, :(::)) ? assignees(first(lhs.args)) :
    Meta.isexpr(lhs, :tuple) ? reduce(vcat, (assignees(arg) for arg in lhs.args); init=Symbol[]) : Symbol[]
typed_assignee(lhs) = Meta.isexpr(lhs, :(::)) || (Meta.isexpr(lhs, :tuple) && any(typed_assignee, lhs.args))

"Names `ex` declares `global` without declaring their types."
function global_names!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    ex.head === :global && foreach(ex.args) do arg
        arg isa Symbol ? push!(names, arg) : Meta.isexpr(arg, :(=)) && union!(names, assignees(first(arg.args)))
    end
    foreach(arg -> global_names!(names, arg), ex.args)
    return names
end

const TOPLEVEL_HEADS = (:using, :import, :export, :public, :module, :macro, :struct, :abstract, :primitive)
const TOPLEVEL_MACROS = (Symbol("@enum"), Symbol("@generated"))

"""
Whether `ex` holds what only top-level code may: imports and exports, definitions of types,
modules and macros, generated functions, global constants, globals with declared types, and
methods of functions that are not local, such as `Base.show(io::IO, ::T) = …`, `(::T)(x) = …`
or those of a name declared `global`. A local scope at top level defines these globally, a
function body cannot hold them.
"""
function toplevel_only(ex, globals::Set{Symbol}=global_names!(Set{Symbol}(), ex))
    ex isa Expr && !(ex.head in (:quote, :inert)) || return false
    ex.head in TOPLEVEL_HEADS && return true
    ex.head === :macrocall && macro_name(ex) in TOPLEVEL_MACROS && return true
    ex.head === :global && any(ex.args) do arg
        arg isa Expr && (arg.head in (:const, :(::), :function) ||
            (arg.head === :(=) && (signature(first(arg.args)) || typed_assignee(first(arg.args)))))
    end && return true
    ex.head === :const && any(arg -> Meta.isexpr(arg, :global) ||
        any(in(globals), Meta.isexpr(arg, :(=)) ? assignees(first(arg.args)) : assignees(arg)), ex.args) && return true
    ex.head === :(=) && typed_assignee(first(ex.args)) && any(in(globals), assignees(first(ex.args))) && return true
    name = definition_name(ex)
    (name isa Symbol ? name in globals : name !== nothing) && return true
    return any(arg -> toplevel_only(arg, globals), ex.args)
end

const TEST_MACROS = Set(Symbol.(["@testset", "@test", "@test_throws", "@test_broken", "@test_skip", "@test_logs",
                                 "@test_warn", "@test_nowarn", "@test_deprecated", "@inferred"]))
"Logging macros, which evaluate their arguments in a `let` block of their own."
const LOGGING_MACROS = Set(Symbol.(["@debug", "@info", "@warn", "@error", "@logmsg"]))
"Macros that expand to a value where they stand, the same in a function."
const VALUE_MACROS = Set(Symbol.(["@__DIR__", "@__FILE__", "@__MODULE__", "@__LINE__", "@isdefined", "@r_str",
                                  "@raw_str", "@s_str", "@v_str", "@big_str"]))
"The heads of the expressions JET analyzes in a closure, when their arguments allow."
const THUNK_SAFE_HEADS = (LS.JET.THUNK_SAFE_TEST_CALL_HEADS..., LS.JET.THUNK_SAFE_TEST_CONTROL_HEADS...,
                          LS.JET.THUNK_SAFE_TEST_LITERAL_HEADS..., LS.JET.THUNK_SAFE_TEST_TYPE_HEADS...)
macro_name(ex) = (name = first(ex.args); name isa Symbol ? name :
    Meta.isexpr(name, :., 2) && last(name.args) isa QuoteNode ? last(name.args).value : nothing)

"""
Whether `ex` is a local scope that defines a function under control flow inside it: a loop,
`let` or `try` block, or a test set, whose body is a local scope already, as a closure's is,
so JET can analyze it in one. A function directly in a local scope needs no control flow to
be defined, nor does one in a `try` block of it.
"""
outlinable_scope(ex) = ex isa Expr && (ex.head in (:for, :while, :let, :try) ||
    (ex.head === :macrocall && macro_name(ex) === Symbol("@testset"))) &&
    any(arg -> controlled_function(arg; nested=true), ex.args)

"""
Whether code binds nothing where it stands: tests and logging, whose bodies and arguments
are local scopes, but for values such as the exception `@test_throws` expects; loops, `let`
and `try` blocks; and calls and control flow of these, of values and of what JET outlines.
"""
binds_nothing(ex) = !(ex isa Expr) || ex.head in (:quote, :inert) ||
    (ex.head === :macrocall ? any(names -> macro_name(ex) in names, (TEST_MACROS, LOGGING_MACROS, VALUE_MACROS)) :
     ex.head in (:block, :if, :elseif) ? all(binds_nothing, ex.args) :
     ex.head in (:for, :while, :let, :try) || (ex.head in THUNK_SAFE_HEADS && all(binds_nothing, ex.args)) ||
     LS.JET.is_test_expression_thunk_safe(ex))

"""
Whether `ex` is a conditional of tests that defines a function in a branch, such as a tier an
environment variable enables. It binds nothing, so JET can analyze it in a closure of its own
rather than define only the closures of the branch its condition takes.
"""
outlinable_tests(ex) = Meta.isexpr(ex, :if) && binds_nothing(ex) && controlled_function(ex)

"""
Whether the worker analyzes the top-level statement `ex` in a function of its own. Code that
includes or evaluates code stays at top level, where JET follows it, as does what only
top-level code may hold, and closures with typed parameters, since lowering would evaluate
their types anyway.
"""
outlinable(ex) = ex isa Expr &&
    (LS.JET.should_wrap_test_expression_in_thunk(ex) || outlinable_scope(ex) || outlinable_tests(ex)) &&
    !stays(ex) && !typed_closure(ex) && !toplevel_only(ex)

"The name tag of the functions the worker outlines top-level code into."
const OUTLINED = :jetsweep_outlined
"Whether `name` is that of a function the worker outlined top-level code into, or of its method."
is_outlined(name::Symbol) = (text = String(name); startswith(text, "#$OUTLINED#") || startswith(text, "##$OUTLINED#"))

symbols!(names::Set{Symbol}, ex) =
    ex isa Symbol ? push!(names, ex) : ex isa Expr ? (foreach(arg -> symbols!(names, arg), ex.args); names) : names

"""
Symbols a method signature reads when the method is defined: argument types, `where` bounds
and the return type, not argument names or default values.
"""
function signature_types!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    if ex.head === :where
        signature_types!(names, first(ex.args))
        for bound in ex.args[2:end]
            Meta.isexpr(bound, (:<:, :>:)) ? symbols!(names, last(bound.args)) :
                Meta.isexpr(bound, :comparison) ? foreach(b -> symbols!(names, b), bound.args[[1, end]]) : nothing
        end
    elseif ex.head === :(::)
        symbols!(names, last(ex.args))
        length(ex.args) == 2 && signature_types!(names, first(ex.args))
    elseif ex.head in (:call, :tuple, :parameters)
        for argument in ex.args
            Meta.isexpr(argument, :kw) && (argument = first(argument.args))
            Meta.isexpr(argument, :...) && (argument = first(argument.args))
            Meta.isexpr(argument, (:(::), :parameters, :curly)) && signature_types!(names, argument)
        end
    elseif ex.head === :curly
        foreach(argument -> symbols!(names, argument), ex.args)
    end
    return names
end

"""
Symbols the signatures of the named functions `ex` defines read, which lowering evaluates
where the function holding them is defined.
"""
function signature_reads!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    definition_name(ex) === nothing || signature_types!(names, first(ex.args))
    foreach(arg -> signature_reads!(names, arg), ex.args)
    return names
end

"Names `ex` may bind, globally or locally: those it assigns, and the functions and types it defines."
function may_bind!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    name = definition_name(ex)
    if name !== nothing
        name isa Symbol && push!(names, name)
    elseif ex.head === :(=)
        union!(names, assignees(first(ex.args)))
    elseif ex.head in (:struct, :abstract, :primitive)
        symbols!(names, ex.args[ex.head === :struct ? 2 : 1])
    elseif ex.head === :macrocall && macro_name(ex) === Symbol("@enum")
        symbols!(names, ex.args[3:end])
    elseif ex.head in (:const, :global, :local)
        union!(names, filter(arg -> arg isa Symbol, ex.args))
    end
    foreach(arg -> may_bind!(names, arg), ex.args)
    return names
end

"The names of the functions the worker moves statements of top-level conditionals into."
const MOVED = Set{Symbol}()

"""
`ex`, a top-level conditional, with each statement of its branches that `outlinable` accepts
replaced by a call of a function `outlined` defines, as are those of conditionals among them.
Those statements are top-level code too, but their conditional binds names, so it cannot be
outlined itself. A statement stays where the signatures of its local functions read names the
conditional may bind, or any name if it imports or includes code: lowering evaluates them
where the function holding the statement is defined, before the conditional.
"""
function outline_statements(ex, outlined::Vector{Any},
                            bound::Set{Symbol}=may_bind!(Set{Symbol}(), ex), opaque::Bool=stays(ex) || imports(ex))
    Meta.isexpr(ex, (:if, :elseif)) &&
        return Expr(ex.head, first(ex.args), (outline_statements(arg, outlined, bound, opaque) for arg in ex.args[2:end])...)
    Meta.isexpr(ex, :block) || return ex
    statements, line = Any[], nothing
    for statement in ex.args
        statement isa LineNumberNode && (line = statement)
        reads = signature_reads!(Set{Symbol}(), statement)
        if outlinable(statement) && (isempty(reads) || (!opaque && isdisjoint(reads, bound)))
            name = gensym(OUTLINED)
            push!(MOVED, name)
            push!(outlined, Expr(:function, Expr(:call, name), Expr(:block, filter(!isnothing, Any[line, statement])...)))
            statement = Expr(:call, name)
        else
            statement = outline_statements(statement, outlined, bound, opaque)
        end
        push!(statements, statement)
    end
    return Expr(:block, statements...)
end

# JET analyzes any top-level expression it can outline the same way, such as
# `x === nothing || atexit(() -> close(x))`, which would otherwise make it evaluate `x`, and
# local scopes, and conditionals of tests. A conditional that binds names, such as a test
# driver's selection of its test files, or a tier that defines what its tests use, has its
# statements outlined instead, into functions defined before it, so that what they define
# needs no condition: the tests of a branch its condition does not take are analyzed too.
Core.eval(LS.JET, quote
    function desugar_main_macrocall(x::Expr)
        x = invoke(desugar_main_macrocall, Tuple{Any}, x)
        if $outlinable(x)
            thunk = gensym($(QuoteNode(OUTLINED)))
            return Expr(:let, Expr(:block), Expr(:block, Expr(:function, Expr(:call, thunk), Expr(:block, x)), Expr(:call, thunk)))
        end
        isexpr(x, :if) || return x
        outlined = Any[]
        x = $outline_statements(x, outlined)
        return isempty(outlined) ? x : Expr(:block, outlined..., x)
    end
end)

"The body of the function the worker outlined top-level code `x` into, if `x` is such code."
function outlined_body(x)
    Meta.isexpr(x, :let, 2) && Meta.isexpr(x.args[2], :block, 2) || return nothing
    f = first(x.args[2].args)
    Meta.isexpr(f, :function, 2) && Meta.isexpr(f.args[1], :call, 1) && f.args[1].args[1] isa Symbol &&
        startswith(String(f.args[1].args[1]), "##$OUTLINED#") || return nothing
    return f.args[2]
end

# JET lowers each top-level statement after the line node of its first line. An outlined
# function starts there too, so that what is reported in it has its location: its loop
# header or `let` bindings where they stand, and its body where that is.
Core.eval(LS.Interpreter, quote
    function JET.lower_with_err_handling(interp::LSInterpreter, node::JS.SyntaxNode, xblk::Expr)
        body = $outlined_body(last(xblk.args))
        body === nothing || !(first(xblk.args) isa LineNumberNode) || pushfirst!(body.args, first(xblk.args))
        interp.current_node[] = node
        @invoke JET.lower_with_err_handling(interp::JET.ConcreteInterpreter, node::JS.SyntaxNode, xblk::Expr)
    end
end)

# JETLS reports a `@test` or `@test_throws` that always fails only in top-level code, since a
# function body is inferred for each specialization, for some of which a test may fail while
# it passes for others. A function the worker outlines top-level code into has one, so its
# tests count too. Its test sets are fail-fast where they would be at top level, so the code
# after such a `@test` is not analyzed there, as at top level.
Core.eval(LS.Analyzer, quote
    function report_failing_test!(analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any})
        def = sv.linfo.def
        def isa Module || (def isa Method && $is_outlined(def.name)) || return false
        length(argtypes) == 2 || return false
        value = CC.widenconditional(argtypes[2])
        if value isa Const && value.val === false
            add_new_report!(analyzer, sv.result, FailingTestReport(sv, Bool, nothing))
            return true
        end
        t = CC.widenconst(value)
        t === Union{} && return false
        CC.hasintersect(t, Bool) && return false
        add_new_report!(analyzer, sv.result, FailingTestReport(sv, t, nothing))
        return true
    end
    function report_failing_test_exception!(analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any})
        def = sv.linfo.def
        def isa Module || (def isa Method && $is_outlined(def.name)) || return false
        length(argtypes) ≥ 3 || return false
        expected = JET.matching_test_exception_type(argtypes[3])
        expected === nothing && return false
        exct = CC.typesubtract(CC.widenconst(argtypes[2]), JET.NoTestException,
            CC.InferenceParams(analyzer).max_union_splitting)
        (exct === Union{} || CC.hasintersect(exct, expected)) && return false
        add_new_report!(analyzer, sv.result, FailingTestReport(sv, exct, (argtypes[3]::Const).val))
        return true
    end
end)

# JETLS drops a report whose innermost frame has no file, as frames of code without line
# information have, such as the closures JET outlines `@test` expressions into. Report it at
# the nearest frame that has one instead.
Core.eval(LS.Analyzer, quote
    function inference_error_report_stack(@nospecialize report::JET.InferenceErrorReport)
        stack = inference_error_report_stack_impl(report)
        stack isa UnitRange{Int} && (stack = convert(StepRange{Int,Int}, stack))
        stack isa StepRange{Int,Int} || error("Invalid implementation of `inference_error_report_stack_impl`")
        while length(stack) > 1 && report.vst[first(stack)].file === :none
            stack = first(stack)+step(stack):step(stack):last(stack)
        end
        @static JETLS_DEV_MODE && assert_valid_report_stack(report, stack, "display")
        return stack
    end
end)

"""
The global that the statement at `pc` of lowered code `code` defines, if it does: a constant
or global it assigns, or a function it creates.
"""
function definition(code::Vector{Any}, pc::Int)
    stmt = code[pc]
    Meta.isexpr(stmt, :method, 1) && return only(stmt.args) isa GlobalRef ? only(stmt.args) : nothing
    Meta.isexpr(stmt, :call, 4) || return nothing
    f, mod, name = stmt.args[1], stmt.args[2], stmt.args[3]
    f in (GlobalRef(Core, :declare_const), GlobalRef(Core, :setglobal!), Core.declare_const, Core.setglobal!) ||
        return nothing
    mod isa GlobalRef && isdefinedglobal(mod.mod, mod.name) && (mod = getglobal(mod.mod, mod.name))
    return mod isa Module && name isa QuoteNode && name.value isa Symbol ? GlobalRef(mod, name.value) : nothing
end

"The globals that the code of `frame` defines on every path to its statement `pc`."
function defined_globals(frame, pc::Int=frame.currpc)
    CC = LS.JET.CC
    code, cfg = frame.src.code, frame.cfg
    block = CC.block_for_inst(cfg, pc)
    domtree = nothing
    globals = Set{GlobalRef}()
    for i in eachindex(code)
        gr = i == pc ? nothing : definition(code, i)
        (gr === nothing || gr in globals) && continue
        b = CC.block_for_inst(cfg, i)
        if b == block
            i < pc && push!(globals, gr)
        else
            domtree === nothing && (domtree = CC.construct_domtree(cfg))
            CC.dominates(domtree, b, block) && push!(globals, gr)
        end
    end
    return globals
end

"For each function the worker moved statements of a conditional into, the globals defined on every path to its call."
const CALLED = Dict{Symbol,Set{GlobalRef}}()
const CALLED_LOCK = ReentrantLock()

"""
Record the globals defined on every path to the call of `f`, a function holding a statement
the worker moved out of a conditional, in top-level code `frame`, which defines `f` before
the conditional and calls it in it: at its last load, whether inference reaches it or not.
"""
function called!(frame, f::GlobalRef)
    @lock CALLED_LOCK haskey(CALLED, f.name) && return nothing
    code = frame.src.code
    pc = findlast(stmt -> stmt == f || (Meta.isexpr(stmt, :(=), 2) && stmt.args[2] == f), code)
    globals = defined_globals(frame, something(pc, frame.currpc))
    @lock CALLED_LOCK CALLED[f.name] = globals
    return nothing
end

mentions(ex, name::Symbol) =
    ex isa GlobalRef ? ex.name === name : ex isa Expr && any(arg -> mentions(arg, name), ex.args)

"Whether `frame` infers top-level code: at top level, or in a function the worker outlined it into."
toplevel_code(frame) = LS.JET.istoplevelframe(frame) || (def = frame.linfo.def; def isa Method && is_outlined(def.name))

"The name of the closure type whose method `frame` infers, if it does."
function closure_name(frame)
    def = frame.linfo.def
    def isa Method || return nothing
    sig = Base.unwrap_unionall(def.sig)
    sig isa DataType && !isempty(sig.parameters) && LS.is_closure_type(sig.parameters[1]) || return nothing
    return Base.unwrap_unionall(sig.parameters[1]).name.name
end

"""
The frame of top-level code that `frame` runs code of: `frame` itself, or the frame calling the
closure `frame` infers, if its code defines it, as the closure runs where that code calls it.
"""
function toplevel_frame(frame)
    CC = LS.JET.CC
    toplevel_code(frame) && return frame
    name = closure_name(frame)
    name === nothing && return nothing
    parent = CC.frame_parent(frame)
    while parent isa CC.InferenceState
        toplevel_code(parent) && return any(stmt -> mentions(stmt, name), parent.src.code) ? parent : nothing
        parent = CC.frame_parent(parent)
    end
    return nothing
end

"""
Whether the global `gr`, which `frame` reads, is defined there because top-level code defines
it on every path to the read: the top-level code `frame` runs code of, or the code before the
call of the function holding a statement the worker moved out of a conditional.
"""
function defined(frame, gr::GlobalRef)
    top = toplevel_frame(frame)
    top === nothing && return false
    gr in defined_globals(top) && return true
    def = top.linfo.def
    def isa Method || return false
    globals = @lock CALLED_LOCK get(CALLED, def.name, nothing)
    return globals !== nothing && gr in globals
end

"Whether `gr` is a constant that JET defines as a placeholder in the world of `frame`."
function placeholder(gr::GlobalRef, frame)
    CC = LS.JET.CC
    partition = Base.lookup_binding_partition(frame.world.this, gr)
    return CC.is_defined_const_binding(CC.binding_kind(partition)) &&
        CC.partition_restriction(partition) isa LS.JET.AbstractBindingState
end

"Reports added from `n` on that `gr` is not defined."
undefined_reports(reports, n::Int, gr::GlobalRef) =
    [i for i in n+1:length(reports) if reports[i] isa LS.Analyzer.UndefVarErrorReport && reports[i].var == gr]

# Lowering puts a `:latestworld` after each constant, global declaration, definition and
# import, and before each closure it constructs. Inference reads globals after one as `Any`
# and records no assignment to them, since the world may have changed. JET ignores one it
# evaluates, but not one it leaves unevaluated, as after an unevaluated `const`: so it lost
# whatever followed in the same statement, such as the later constants of `const A, B = f()`
# or of a conditional, which it reported undefined, and every report after a closure in a
# loop. JET analyzes a statement in the world its evaluation left, and records itself the
# bindings of what it leaves unevaluated, so a world update changes nothing it knows.
#
# The code JET analyzes after such a statement now meets imprecisions of its own, which this
# override corrects at loads of globals, each a statement of its own: correcting them in
# JET's load of a binding, which all of inference calls, would recompile all of inference in
# each worker. JET records a constant or global that a conditional assigns as one that may be
# undefined, as it is where code that runs later reads it, but not where top-level code reads
# it after defining it, as `const B = f(A)` does after `const A = g()` in the same branch; nor
# does it record functions and types that a branch it does not take defines, so it reported
# them undefined, even where they are defined, and analyzed nothing after that in the branch.
# Where top-level code defines a global on every path to a read, the read finds it defined,
# as what JET knows of it, or as any value if JET knows nothing of it. This holds for the code
# the worker outlines too, top-level code in a function of its own, and for the closures
# top-level code defines, which run where it calls them; and code moved out of a conditional
# finds what the conditional defines before the call of the function holding it. And JET defines a constant it leaves unevaluated
# as a placeholder holding what it knows of the value, inferring its loads as that, with the
# effects of a constant's load: so inference would evaluate a call that reads one natively,
# as of `name() = NAME` once `const NAME = f()` is inferred as `Any`, and get the placeholder
# itself, for which the function it is passed to then reports a method error. A load of a
# placeholder is not consistent, so no such call is evaluated.
Core.eval(LS.JET, quote
    function CC.abstract_eval_basic_statement(analyzer::ToplevelAbstractAnalyzer, @nospecialize(stmt),
            sstate::StatementState, frame::InferenceState, result::Union{Nothing,Future{RTEffects}})
        toplevel = istoplevelframe(frame)
        isexpr(stmt, :latestworld) && toplevel &&
            return CC.AbstractEvalBasicStatementResult(nothing, Any, nothing, nothing, nothing, #=saw_latestworld=#false)
        lhs = isexpr(stmt, :(=), 2) ? stmt.args[1] : nothing
        load = lhs === nothing ? stmt : stmt.args[2]
        load isa GlobalRef && result === nothing ||
            return @invoke CC.abstract_eval_basic_statement(analyzer::AbstractAnalyzer, stmt::Any,
                sstate::StatementState, frame::InferenceState, result::Union{Nothing,Future{RTEffects}})
        toplevel && load.name in $MOVED && $called!(frame, load)
        reports = get_reports(analyzer, frame.result)
        n = length(reports)
        ret = @invoke CC.abstract_eval_basic_statement(analyzer::AbstractAnalyzer, stmt::Any,
            sstate::StatementState, frame::InferenceState, result::Union{Nothing,Future{RTEffects}})
        if length(reports) > n
            undefined = $undefined_reports(reports, n, load)
            if !isempty(undefined) && $defined(frame, load)
                deleteat!(reports, undefined)
                if ret isa CC.AbstractEvalBasicStatementResult && ret.rt === Union{}
                    changes = lhs isa SlotNumber ? CC.StateUpdate(lhs, CC.VarState(Any, false)) : ret.changes
                    ret = CC.AbstractEvalBasicStatementResult(Any, ret.exct, CC.generic_getglobal_effects, changes,
                                                              ret.refinements, ret.currsaw_latestworld)
                end
            end
        end
        if ret isa CC.AbstractEvalBasicStatementResult && ret.effects isa CC.Effects && $placeholder(load, frame)
            (; rt, exct, effects, changes, refinements, currsaw_latestworld) = ret
            effects = CC.Effects(effects; consistent=CC.ALWAYS_FALSE)
            ret = CC.AbstractEvalBasicStatementResult(rt, exct, effects, changes, refinements, currsaw_latestworld)
        end
        return ret
    end
end)

# JET evaluates every `eval` call, since it may define anything; `include_string` calls too.
Core.eval(LS.JET, quote
    known_names(func::Symbol) = func === :eval ? (:eval, :include_string) : (func,)
    function is_known_call(@nospecialize(stmt), func::Symbol, stmts::Vector{Any})
        isexpr(stmt, :call) || return false
        f = stmt.args[1]
        f isa SSAValue && (f = stmts[f.id])
        return (f isa Symbol && f in known_names(func)) || (f isa GlobalRef && f.name in known_names(func))
    end
    function is_known_getproperty(@nospecialize(stmt), func::Symbol, stmts::Vector{Any})
        isexpr(stmt, :call) && length(stmt.args) >= 3 || return false
        f = stmt.args[1]
        f isa SSAValue && (f = stmts[f.id])
        callee_matches(f, Base, :getproperty) || callee_matches(f, Core, :getproperty) ||
            callee_matches(f, CC, :getproperty) || return false
        return any(name -> JuliaInterpreter.is_quotenode_egal(stmt.args[3], name), known_names(func))
    end
end)

"""
The module analyses run in, empty to keep worker globals out of reach of analyzed code. JET
finds it by its path from `Main`.
"""
const CONTEXT = Core.eval(Main, :(module JETSweepAnalysis end))

# JETLS names what it analyzes in JET's virtual module of `Main` as if `Main` defined it,
# leaving `Main.` out. Name what is analyzed in the worker's context so too, whether a message
# names the virtual module or the context itself, as the locations of methods do, leaving out
# only those modules: JET leaves out every `Main.`, that of `MyMain.x` too.
"The worker's context in messages: its path before a name, or standing alone."
const CONTEXT_PATH = Regex("\\Q$(CONTEXT)\\E(\\.|(?![\\w!]))")
Core.eval(LS.JET, quote
    function (postprocessor::PostProcessor)(s::AbstractString)
        isdefined(postprocessor, :actual2virtual) || return s
        actual, virtual = postprocessor.actual2virtual
        actual == $(string(CONTEXT)) || return replace(s, virtual => actual)
        s = replace(s, virtual * "." => "", virtual => "Main")
        return replace(s, $CONTEXT_PATH => context -> endswith(context, ".") ? "" : "Main")
    end
end)

# JETLS dispatches in the world it was loaded in, to stay clear of analyzed code.
LS.advance_server_world!()

# Codes after which JETLS analyzes no further code of the unit. JET stops at any parse
# error, which JETLS reports only as a syntax diagnostic.
const STOPS = ("toplevel/error", "toplevel/missing-concretization", "toplevel/concretization-timeout",
               "toplevel/analysis-stopped", "syntax/parse-error")

"""
Collects error-level log records. The analyzer's errors signal analysis problems it does not
raise. Julia's loader logs, rather than raises, the failure of a package extension.
"""
struct ErrorLog{L<:Base.CoreLogging.AbstractLogger} <: Base.CoreLogging.AbstractLogger
    parent::L
    analyzer::Vector{String}
    loading::Vector{String}
    lock::ReentrantLock
end
ErrorLog(parent) = ErrorLog(parent, String[], String[], ReentrantLock())
Base.CoreLogging.min_enabled_level(log::ErrorLog) = Base.CoreLogging.min_enabled_level(log.parent)
Base.CoreLogging.shouldlog(log::ErrorLog, args...) = Base.CoreLogging.shouldlog(log.parent, args...)
Base.CoreLogging.catch_exceptions(::ErrorLog) = false
"The exception a log record carries, which loggers accept bare, with a backtrace or as a stack."
_exception(e) = e isa Exception ? e : e isa Base.ExceptionStack ? (isempty(e) ? e : _exception(last(e))) :
    e isa NamedTuple && haskey(e, :exception) ? _exception(e.exception) : e isa Tuple ? _exception(first(e)) : e
function Base.CoreLogging.handle_message(log::ErrorLog, level, message, _module, args...; kwargs...)
    if level >= Base.CoreLogging.Error && _module isa Module
        text = string(message)
        haskey(kwargs, :exception) && (text *= " " * sprint(showerror, _exception(kwargs[:exception])))
        origin = nameof(Base.moduleroot(_module))
        @lock log.lock push!(origin in (:JETLSCore, :JETLS, :JET, :Revise) ? log.analyzer :
                             origin === :Base ? log.loading : String[], text)
    end
    return Base.CoreLogging.handle_message(log.parent, level, message, _module, args...; kwargs...)
end

canonical(path::AbstractString) = ispath(path) ? realpath(path) : abspath(path)

"Load a package, or an extension with its parent and triggers, and return its module."
function load(request, log::ErrorLog)
    package = Base.PkgId(Base.UUID(request["uuid"]), request["package"])
    parent = Base.require(package)
    # Revise resolves a file's outer `module` block by name; bind the loaded module so a
    # single-file package is not attributed to `Base.__toplevel__`.
    bind(parent)
    name = request["extension"]
    isempty(name) && return parent
    for (trigger, uuid) in sort!(collect(request["triggers"]); by=first)
        Base.require(Base.PkgId(Base.UUID(uuid), trigger))
    end
    # A failed extension can still be registered, half defined, so check the loader's log.
    failure = findfirst(text -> occursin("extension $name ", text), log.loading)
    failure === nothing || error("extension $name failed to load: ", log.loading[failure])
    extension = Base.get_extension(parent, Symbol(name))
    extension isa Module || error("extension $name did not load with its triggers")
    request["kind"] == "extension" && canonical(something(pathof(extension), "")) != canonical(request["entry"]) &&
        error("extension $name loaded from $(pathof(extension)), not $(request["entry"])")
    bind(extension)
    return extension
end

function bind(mod::Module)
    name = nameof(mod)
    if !isdefined(Base.__toplevel__, name)
        Core.eval(Base.__toplevel__, Expr(:const, Expr(:(=), name, mod)))
    end
    return nothing
end

"A binding's name as `import` syntax takes it, or `nothing`."
function import_name(name::Symbol)
    text = String(name)
    startswith(text, '#') && return nothing
    text = Base.isidentifier(name) || Base.isoperator(name) || startswith(text, '@') ? text : "var$(repr(text))"
    return Meta.isexpr(Meta.parse("import M: $text"; raise=false), :import) ? text : nothing
end

"""
An entry file that recreates the scope of `target`, a package's module or an extension's,
before including `file`: the modules it uses and every binding it defines or imports. A
used module is named through `target` when `target` binds it, since its package need not be
loadable from the environment by name: a dependency of a dependency, say. An extension is
reached through its package, since it has no name to load it by.
"""
function orphan_entry(target::Module, file::String, package::String, extension::String)
    io = IOBuffer()
    println(io, "const Main = @__MODULE__\nimport ", package)
    reference = package
    if !isempty(extension)
        # Evaluated, so that analysis knows the module.
        println(io, "@eval const ", extension, " = Base.get_extension(", package, ", :", extension, ")")
        reference = "." * extension
    end
    path(m) = isdefined(target, nameof(m)) && getglobal(target, nameof(m)) === m ?
        "$reference.$(nameof(m))" : join(fullname(m), '.')
    for m in ccall(:jl_module_usings, Any, (Any,), target)
        m === Base || m === Core || m === target || first(fullname(m)) === :Main || println(io, "using ", path(m))
    end
    bindings = [text for name in names(target; all=true, imported=true)
                if !(name in (:eval, :include)) && isdefined(target, name)
                for text in (import_name(name),) if text !== nothing]
    isempty(bindings) || println(io, "import ", reference, ": ", join(bindings, ", "))
    println(io, "include(", repr(file), ")")
    return String(take!(io))
end

"`target` and the modules defined inside it."
function modules(target::Module, found=Module[target])
    for name in names(target; all=true)
        isdefined(target, name) || continue
        value = getglobal(target, name)
        value isa Module && value !== target && parentmodule(value) === target && !(value in found) &&
            (push!(found, value); modules(value, found))
    end
    return found
end

"""
`toplevel/abstract-field` reports for the structs of a loaded package. JETLS reports these
while interpreting top-level code, which its package analysis loads instead.
"""
function abstract_fields(target::Module, files::Vector{String})
    trees = Dict(file => LS.JS.parseall(LS.JS.SyntaxNode, read(file, String); filename=file, ignore_errors=true)
                 for file in files)
    reports = LS.ToplevelWarningReport[]
    for mod in modules(target), name in names(mod; all=true)
        isdefined(mod, name) || continue
        value = getglobal(mod, name)
        value isa Type || continue
        type = Base.unwrap_unionall(value)
        type isa DataType && isstructtype(type) && parentmodule(type) === mod && nameof(type) === name &&
            !LS.is_closure_type(type) || continue
        for (fname, ftype) in zip(fieldnames(type), type.types)
            LS.is_abstract_fieldtype(ftype) || continue
            for (file, tree) in trees
                field = LS.try_extract_field_line(tree, name, fname)
                field === nothing && continue
                push!(reports, LS.AbstractFieldReport(file, field, value, fname, ftype))
                break
            end
        end
    end
    return reports
end

"""
The end of a range that starts at `start` in `text` as the file now is. JETLS ends a whole-line
range at character typemax(Int32), which LSP reads as the end of the line: before its "\\r\\n"
or "\\n". A line the file no longer has, or a range the file's changes would turn around, ends
where it starts.
"""
function range_end(text::Vector{UInt8}, starts::Vector{Int}, encoding, start, stop)
    if stop.character == typemax(Int32)
        stop.line < length(starts) || return start
        offset = LS._xy_to_offset(text, stop, encoding, starts)
        1 < offset <= length(text) && text[offset] == UInt8('\n') && text[offset-1] == UInt8('\r') && (offset -= 1)
        stop = LS._offset_to_xy(text, offset, encoding, starts)
    end
    return (stop.line, stop.character) < (start.line, start.character) ? start : stop
end

"""
Diagnostics of original files, with positions in `encoding`. Skipped includes are reported
as missing coverage instead.
"""
function findings(uri2diagnostics, generated::String, encoding)
    rows = Dict{String,Any}[]
    for (uri, diagnostics) in uri2diagnostics
        file = LS.uri2filepath(uri)
        (file === nothing || canonical(file) == generated) && continue
        text = isfile(file) ? read(file) : UInt8[]
        starts = LS.build_line_starts(text)
        for diagnostic in diagnostics
            diagnostic.code == "toplevel/analysis-skipped" && continue
            (; start) = diagnostic.range
            stop = range_end(text, starts, encoding, start, diagnostic.range.var"end")
            push!(rows, Dict{String,Any}("file" => file,
                "line" => start.line + 1, "column" => start.character + 1,
                "end_line" => stop.line + 1, "end_column" => stop.character + 1,
                "severity" => Int(something(diagnostic.severity, LS.DiagnosticSeverity.Error)),
                "code" => string(something(diagnostic.code, "")), "message" => LS.get_raw_message(diagnostic)))
        end
    end
    sort!(unique!(rows); by=row -> (row["file"], row["line"], row["column"], row["code"], row["message"]))
    return rows
end

"The line before each statement a prelude copies, naming where the statement is from."
const MARKER = r"^#= (.+):(\d+) =#$"

"""
The original file and line of line `line` of the generated entry `file`, if a statement its
prelude copies is there: after its marker, inside `@eval begin … end` if it is evaluated.
"""
function original(file::String, line::Int)
    lines = readlines(file)
    marker = findlast(i -> occursin(MARKER, lines[i]), 1:min(line, length(lines)))
    marker === nothing && return nothing
    source, start = match(MARKER, lines[marker])
    # The statement ends where it parses to, before any include that follows the prelude.
    text = join(lines[marker+1:end], '\n')
    span = count('\n', text[1:prevind(text, last(Meta.parse(text, 1; raise=false)))])
    line - marker <= span || return nothing
    evaluated = lines[marker+1] == "@eval begin"
    return source, parse(Int, start) + clamp(line - marker - 1 - evaluated, 0, span - 1 - 2evaluated)
end

function analyze(request, log::ErrorLog)
    timings = Dict{String,Float64}()
    started = time()
    environment = request["environment"]
    kind = request["kind"]
    LS.JETLS_VERSION[] = JETLS.JETLS_VERSION
    LS.JETLS_MODULE[] = JETLS
    LS.Revise === nothing && error("JETLS was loaded without its Revise backend (JETLS_DEV_MODE)")
    Base.ACTIVE_PROJECT[] = joinpath(environment, "Project.toml")
    empty!(LOAD_PATH)
    push!(LOAD_PATH, "@", "@stdlib")
    empty!(ARGS)
    append!(ARGS, request["args"])
    # A script runs as the program, so `abspath(PROGRAM_FILE) == @__FILE__` holds as it would.
    kind in ("test", "script", "orphan") && (Base.PROGRAM_FILE = request["entry"])
    merge!(ENV, request["env"])
    LS.FULL_ANALYSIS_CONTEXT[] = CONTEXT
    target = nothing
    if kind in ("package", "extension", "orphan")
        target = load(request, log)
        timings["load"] = time() - started
        if kind == "orphan"
            # The package's bindings exist only in the world after loading it.
            write(request["generated"], Base.invokelatest(orphan_entry, target, request["entry"], request["package"],
                                                          request["extension"]))
            target = nothing
        end
    end
    generated = canonical(request["generated"])
    cd(dirname(request["entry"]))
    server = LS.start_cli_server(request["config"])
    server.state.root_path = request["root"]
    server.state.workspaceFolders = [LS.filepath2uri(request["root"])]
    try
        LS.start_signature_analysis_workers!(server)
        LS.start_analysis_worker!(server)
        if target === nothing
            uri = LS.filepath2uri(generated)
            entry = LS.ScriptInEnvAnalysisEntry(environment, uri)
        else
            uri = LS.filepath2uri(request["entry"])
            entry = LS.NewAnalysisEntry(Base.PkgId(target), environment)
        end
        LS.cache_file_info!(server, uri, 1, read(LS.uri2filepath(uri), String))
        done = Base.Event()
        LS.schedule_analysis!(server, uri, entry, false; completion=done, notify_diagnostics=false, debounce=0.0)
        wait(done)
        mark = time()
        timings["analysis"] = mark - started - get(timings, "load", 0.0)
        info = LS.get_analysis_info(server.state.analysis_manager, uri)
        info isa LS.AnalysisResult || error("JETLS produced no analysis result: $(typeof(info))")
        files = [canonical(file) for file in (LS.uri2filepath(uri) for uri in keys(info.analyzed_file_infos))
                 if file !== nothing]
        uris = LS.collect_workspace_uris(server)
        diagnostics = LS.get_full_diagnostics(server)
        if target !== nothing
            reports = Base.invokelatest(abstract_fields, target, files)
            LS.toplevel_warning_reports_to_diagnostics!(diagnostics, reports, server, LS.JET.PostProcessor())
        end
        progress = LS.ProgressContext(LS.PROGRESS_NONE, stderr)
        LS.run_per_file_diagnostics!(diagnostics, uris, server, request["root"], progress; skip_analysis=false)
        # Before the user's severity configuration applies, which could turn the stops off.
        reasons = String[]
        for (uri, list) in diagnostics, diagnostic in list
            code = string(something(diagnostic.code, ""))
            code in STOPS || continue
            file, line = something(LS.uri2filepath(uri), string(uri)), Int(diagnostic.range.start.line) + 1
            # A stop in a prelude is at the driver's statement it copies, as the driver's unit
            # reports it.
            canonical(file) == generated && ((file, line) = something(original(generated, line), (file, line)))
            push!(reasons, "analysis stopped at $file:$line [$code]: " *
                first(split(LS.get_raw_message(diagnostic), '\n')))
        end
        for (uri, list) in diagnostics
            LS.apply_diagnostic_config!(list, server.state.config_manager, uri, request["root"])
        end
        timings["lowering"] = time() - mark
        return Dict{String,Any}("analyzed" => sort!(filter(!=(generated), files)),
                                "findings" => findings(diagnostics, generated, server.state.encoding),
                                "reasons" => unique!(reasons),
                                "timings" => timings)
    finally
        LS.cleanup_cli_tasks(server)
    end
end

function main(request_file::String, result_file::String)
    request = TOML.parsefile(request_file)
    log = ErrorLog(Base.CoreLogging.current_logger())
    result = try
        Base.CoreLogging.with_logger(() -> analyze(request, log), log)
    catch err
        Dict{String,Any}("error" => sprint(showerror, err, catch_backtrace()))
    end
    result["errors"] = log.analyzer
    # Whole or not at all, since JETSweep reads the result once the worker exits.
    open(io -> TOML.print(io, result; sorted=true), result_file * ".partial", "w")
    mv(result_file * ".partial", result_file; force=true)
    return 0
end

end # module JETSweepWorker

length(ARGS) == 2 || error("usage: analyze.jl REQUEST.toml RESULT.toml")
exit(JETSweepWorker.main(ARGS[1], ARGS[2]))
