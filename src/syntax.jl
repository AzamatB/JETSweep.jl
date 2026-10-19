# Static source facts. Parsing never executes user code; anything that depends on run-time
# values stays unresolved and is reported as such.

const JS = Base.JuliaSyntax

"An `include` call: its statically resolved target, or `\"\"` when only known at run time."
struct Include
    target::String
    line::Int
    "Whether analysis follows the call: JETLS skips includes inside function bodies."
    followed::Bool
end

struct Syntax
    includes::Vector{Include}
    "Parse failures and includes that cannot be resolved statically."
    notes::Vector{String}
end

_name(ex::Symbol) = String(ex)
_name(ex::GlobalRef) = String(ex.name)
_name(ex::QuoteNode) = _name(ex.value)
_name(ex::Expr) = ex.head === :. ? _name(last(ex.args)) : ""
_name(::Any) = ""

_macro_name(ex) = ex isa Expr && ex.head === :macrocall ? _name(first(ex.args)) : ""

_signature(ex) = ex isa Expr && (ex.head === :call ||
    (ex.head in (:where, :(::)) && _signature(first(ex.args))))
_method(ex) = ex isa Expr &&
    (ex.head in (:function, :macro, :->) || (ex.head === :(=) && _signature(first(ex.args))))
"`include(path)`, `include(mapexpr, path)`, `Base.include(mod, path)` or `Base.include(mapexpr, mod, path)`."
_is_include(ex) = ex isa Expr && ex.head === :call && _name(first(ex.args)) == "include" &&
    2 <= length(ex.args) <= 4

_symbols!(names::Set{Symbol}, ex::Symbol) = push!(names, ex)
_symbols!(names::Set{Symbol}, ex::Expr) = (foreach(arg -> _symbols!(names, arg), ex.args); names)
_symbols!(names::Set{Symbol}, ex::QuoteNode) = _symbols!(names, ex.value)
_symbols!(names::Set{Symbol}, ::Any) = names
_symbols(ex) = _symbols!(Set{Symbol}(), ex)

"Evaluate a path expression built from literals, `@__DIR__`, `@__FILE__` and path calls."
function _path(ex, file::String, bindings::Dict{Symbol,String}, packages::Dict{String,String})
    ex isa String && return ex
    ex isa Symbol && return get(bindings, ex, nothing)
    ex isa Expr || return nothing
    if ex.head === :macrocall
        _macro_name(ex) == "@__DIR__" && return dirname(file)
        _macro_name(ex) == "@__FILE__" && return file
        _macro_name(ex) == "@raw_str" && length(ex.args) == 3 && last(ex.args) isa String && return last(ex.args)
        return nothing
    elseif ex.head === :string
        parts = [_path(arg, file, bindings, packages) for arg in ex.args]
        return all(part -> part isa String, parts) ? join(parts) : nothing
    elseif ex.head !== :call
        return nothing
    end
    name = _name(first(ex.args))
    if name == "pkgdir"
        length(ex.args) >= 2 || return nothing
        root = get(packages, _name(ex.args[2]), nothing)
        parts = [_path(arg, file, bindings, packages) for arg in ex.args[3:end]]
        return root !== nothing && all(part -> part isa String, parts) ? joinpath(root, parts...) : nothing
    end
    parts = [_path(arg, file, bindings, packages) for arg in ex.args[2:end]]
    all(part -> part isa String, parts) && !isempty(parts) || return nothing
    name == "joinpath" && return joinpath(parts...)
    name == "normpath" && return normpath(parts...)
    name == "dirname" && length(parts) == 1 && return dirname(only(parts))
    name == "*" && return join(parts)
    # A relative `abspath` depends on the working directory, which is not guessed.
    name == "abspath" && isabspath(first(parts)) && return abspath(parts...)
    return nothing
end

const _UPDATES = (:+=, :-=, :*=, :/=, :\=, :^=, :÷=, :%=, :|=, :&=, :⊻=, :<<=, :>>=, :>>>=, :.=, :$=)

"Record or forget a path binding for an assignment-like expression."
function _rebind!(bindings::Dict{Symbol,String}, ex::Expr, file::String, packages::Dict{String,String})
    lhs = first(ex.args)
    if ex.head === :(=) && lhs isa Symbol
        value = _path(last(ex.args), file, bindings, packages)
        value === nothing ? delete!(bindings, lhs) : (bindings[lhs] = value)
    elseif ex.head === :(=) || ex.head in _UPDATES
        foreach(name -> delete!(bindings, name), _symbols(lhs))
    end
    return bindings
end

_assigned!(names::Set{Symbol}, ex) = names
function _assigned!(names::Set{Symbol}, ex::Expr)
    (ex.head === :(=) || ex.head in _UPDATES) && !_signature(first(ex.args)) && _symbols!(names, first(ex.args))
    foreach(arg -> _assigned!(names, arg), ex.args)
    return names
end

"Names that iteration specifications or `let` bindings introduce."
_loop_names(spec) = spec isa Expr && spec.head in (:(=), :block, :filter) ?
    (spec.head === :(=) ? _symbols(first(spec.args)) : mapreduce(_loop_names, union, spec.args; init=Set{Symbol}())) :
    (spec isa Symbol ? Set([spec]) : Set{Symbol}())

"""
    parse_source(file, packages=Dict()) -> Syntax

Find the `include` calls of `file`. `packages` maps package names to their directories,
which resolves `pkgdir(Name)` paths.
"""
function parse_source(file::String, packages::Dict{String,String}=Dict{String,String}())
    includes, notes = Include[], String[]
    tree = try
        Meta.parseall(read(file, String); filename=file)
    catch err
        return Syntax(includes, ["$file: cannot be read: $(sprint(showerror, err))"])
    end
    line = 1
    function visit(ex, bindings::Dict{Symbol,String}, followed::Bool)
        ex isa LineNumberNode && (line = ex.line; return)
        ex isa Expr || return
        head = ex.head
        if head in (:error, :incomplete)
            push!(notes, "$file:$line: cannot be parsed")
            return
        elseif head === :quote
            return
        elseif _is_include(ex)
            target = _path(last(ex.args), file, bindings, packages)
            if target === nothing
                push!(notes, "$file:$line: include target is only known at run time")
                push!(includes, Include("", line, followed))
            else
                push!(includes, Include(normpath(dirname(file), target), line, followed))
            end
            return
        elseif _method(ex)
            # Parameters shadow outer bindings; the body is analyzed, never run, at top level.
            inner = copy(bindings)
            foreach(name -> delete!(inner, name), _symbols(first(ex.args)))
            foreach(arg -> visit(arg, inner, false), ex.args[2:end])
            return
        elseif head === :module
            visit(last(ex.args), Dict{Symbol,String}(), followed)
            return
        elseif head === :(=) || head in _UPDATES
            _rebind!(bindings, ex, file, packages)
        end
        # Bindings made inside conditionals and scopes do not leak outward.
        scoped = head in (:let, :for, :while, :if, :elseif, :try, :&&, :||, :generator, :comprehension)
        inner = scoped ? copy(bindings) : bindings
        if head in (:for, :let, :generator)
            specs = head === :generator ? ex.args[2:end] : ex.args[1:1]
            foreach(spec -> foreach(name -> delete!(inner, name), _loop_names(spec)), specs)
        end
        foreach(arg -> visit(arg, inner, followed), ex.args)
        scoped && foreach(name -> delete!(bindings, name), _assigned!(Set{Symbol}(), ex))
        return
    end
    visit(tree, Dict{Symbol,String}(), true)
    return Syntax(unique!(includes), unique!(notes))
end

# Top-level statements
# ====================

"Top-level statements of a file with their expressions and source text, flattening blocks."
function _statements(file::String; modules::Bool=false)
    text = read(file, String)
    tree = JS.parseall(JS.SyntaxNode, text; filename=file, ignore_errors=true)
    statements = Tuple{JS.SyntaxNode,Any}[]
    function flatten(node)
        kind = JS.kind(node)
        if kind in (JS.K"toplevel", JS.K"block")
            foreach(flatten, JS.children(node))
        elseif modules && kind == JS.K"module"
            flatten(last(JS.children(node)))
        elseif kind != JS.K"error"
            ex = try
                Expr(node)
            catch
                nothing
            end
            ex === nothing || push!(statements, (node, ex))
        end
    end
    flatten(tree)
    return text, statements
end

_source_text(node::JS.SyntaxNode, text::String) = String(codeunits(text)[JS.byte_range(node)])

_assignees(lhs::Symbol) = [lhs]
_assignees(lhs::Expr) = lhs.head === :(::) ? _assignees(first(lhs.args)) :
    lhs.head === :tuple ? reduce(vcat, (_assignees(arg) for arg in lhs.args); init=Symbol[]) : Symbol[]
_assignees(::Any) = Symbol[]

"The globals a top-level assignment binds and its value, or `nothing` for other statements."
function _assignment(ex)
    ex isa Expr || return nothing
    ex.head === :macrocall && _macro_name(ex) == "@doc" && return _assignment(last(ex.args))
    ex.head in (:const, :global) && length(ex.args) == 1 && return _assignment(only(ex.args))
    ex.head === :(=) && !_signature(first(ex.args)) || return nothing
    names = _assignees(first(ex.args))
    return isempty(names) ? nothing : (names, last(ex.args))
end

"Whether a top-level statement is a definition, possibly decorated by macros."
function _definition(ex)
    ex isa Expr || return false
    (_method(ex) || ex.head in (:struct, :abstract, :primitive, :module)) && return true
    ex.head === :macrocall || return false
    _macro_name(ex) == "@enum" && return true
    _macro_name(ex) == "@eval" && return false
    return any(_definition, ex.args)
end

"The names a definition or import statement binds."
function _bound_names(ex)
    ex isa Expr || return Symbol[]
    if ex.head in (:using, :import)
        names = Symbol[]
        for path in ex.args
            path isa Expr || continue
            if path.head === :(:)
                append!(names, (last(p.args) for p in path.args[2:end] if p isa Expr && !isempty(p.args)))
            elseif path.head === :as
                push!(names, last(path.args))
            elseif path.head === :. && !isempty(path.args)
                push!(names, last(path.args))
            end
        end
        return filter(name -> name isa Symbol, names)
    elseif ex.head === :macrocall
        return reduce(vcat, (_bound_names(arg) for arg in ex.args); init=Symbol[])
    elseif ex.head in (:struct, :module)
        name = ex.args[2]
        name isa Expr && name.head === :(<:) && (name = first(name.args))
        name isa Expr && name.head === :curly && (name = first(name.args))
        return name isa Symbol ? [name] : Symbol[]
    elseif ex.head in (:abstract, :primitive)
        return _bound_names(Expr(:struct, false, first(ex.args)))
    elseif _method(ex) && ex.head !== :->
        signature = first(ex.args)
        while signature isa Expr && signature.head in (:where, :(::))
            signature = first(signature.args)
        end
        signature isa Expr && signature.head === :call || return Symbol[]
        name = first(signature.args)
        return name isa Symbol ? [ex.head === :macro ? Symbol("@", name) : name] : Symbol[]
    end
    return Symbol[]
end

# Concretization
# ==============
#
# Script analysis evaluates definitions but not assignments, so a definition or `include`
# that needs an assigned value stops it (`toplevel/missing-concretization`). JETSweep lets
# JETLS evaluate top-level statements that cannot have side effects: assignments of values
# built from literals, paths, names already bound and pure functions of them, and guards
# such as `if !@isdefined(X) const X = Package end`. In a test driver it also evaluates the
# assignments that select the files the driver includes at run time.

const _PURE_NAMES = Set([:nothing, :missing, :true, :false, :Inf, :NaN, :pi, :π, :ℯ])
const _PURE_CALLS = Set(Symbol.(split("""
    joinpath normpath dirname basename splitext splitdir string repr * + - / // ^ % ÷ \\ div rem mod
    fld cld min max abs sqrt cbrt exp exp2 exp10 log log2 log10 sin cos tan hypot round floor ceil
    trunc length Dict Set Pair => : range collect Tuple NamedTuple Symbol Int Int8 Int16 Int32 Int64
    UInt UInt8 UInt16 UInt32 UInt64 Float16 Float32 Float64 Bool String Char BigInt BigFloat
    Rational Complex zero one typemax typemin == != < <= > >= ! isempty first last reverse sort vcat
    hcat lowercase uppercase VersionNumber fill zeros ones sum prod maximum minimum in ∈ ∉ get
    haskey getindex isodd iseven deg2rad rad2deg""")))
const _PURE_MACROS = Set(["@__DIR__", "@__FILE__", "@__MODULE__", "@r_str", "@raw_str", "@v_str", "@big_str",
                          "@isdefined"])

function _pure_callee(f)
    f isa Symbol && return f in _PURE_CALLS || f === :isdefined
    return f isa Expr && f.head === :. && first(f.args) === :Base && Symbol(_name(f)) in _PURE_CALLS
end

"Whether evaluating `ex` is free of side effects, reading only `known` names, literals and Base."
function _pure(ex, known::Set{Symbol})
    ex isa Union{Number,String,Char,Nothing,LineNumberNode} && return true
    ex isa QuoteNode && return ex.value isa Symbol
    ex isa Symbol && return ex in known || ex in _PURE_NAMES || isdefined(Base, ex)
    ex isa Expr || return false
    pure(args) = all(arg -> _pure(arg, known), args)
    ex.head === :macrocall && return _macro_name(ex) in _PURE_MACROS &&
        all(arg -> arg isa Union{Symbol,String,LineNumberNode}, ex.args[2:end])
    ex.head in (:tuple, :vect, :vcat, :hcat, :row, :nrow, :ncat, :parameters, :string, :&&, :||, :if,
                :elseif, :comparison, :ref, :curly) && return pure(ex.args)
    ex.head === :. && return length(ex.args) == 2 && last(ex.args) isa QuoteNode && _pure(first(ex.args), known)
    ex.head in (:kw, :(=)) && return first(ex.args) isa Symbol && _pure(last(ex.args), known)
    ex.head === :call && return _pure_callee(first(ex.args)) && pure(ex.args[2:end])
    return false
end

_subexpressions(ex) = ex isa Expr ? vcat(Any[ex], (_subexpressions(arg) for arg in ex.args)...) : Any[ex]
_checks_definition(ex) = _macro_name(ex) == "@isdefined" ||
    (ex isa Expr && ex.head === :call && _name(first(ex.args)) == "isdefined")

"Whether `ex` is a definition guard, as in `if !@isdefined(X) const X = Package end`, free of side effects."
function _guard(ex, known::Set{Symbol})
    ex isa Expr && ex.head in (:if, :elseif) || return false
    condition = first(ex.args)
    _pure(condition, known) && any(_checks_definition, _subexpressions(condition)) || return false
    for branch in ex.args[2:end]
        if branch isa Expr && branch.head === :elseif
            _guard(branch, known) || return false
            continue
        end
        for statement in (branch isa Expr && branch.head === :block ? branch.args : Any[branch])
            statement isa LineNumberNode && continue
            assignment = _assignment(statement)
            assignment === nothing ? (_definition(statement) || return false) :
                (_pure(last(assignment), known) || return false)
        end
    end
    return true
end

"""
Whether MacroTools would read a name in `ex` as a pattern variable, which could match other
statements. Macro names such as `@__DIR__` are exempt: only a macro could take their place.
"""
_wildcards(ex) = any(_symbols(ex)) do name
    text = String(name)
    !startswith(text, '@') && (endswith(text, '_') || endswith(text, "__str"))
end

"Names of a driver's top-level assignments that its run-time includes depend on, transitively."
function include_selectors(file::String)
    needed = Set{Symbol}()
    function visit(ex, context::Vector{Any})
        ex isa Expr && ex.head !== :quote && !_method(ex) || return
        if _is_include(ex)
            _symbols!(needed, last(ex.args))
            foreach(c -> _symbols!(needed, c), context)
            return
        end
        condition = ex.head in (:for, :while, :if, :elseif) ? Any[first(ex.args)] : Any[]
        foreach(arg -> visit(arg, [context; condition]), ex.args)
    end
    visit(Meta.parseall(read(file, String); filename=file), Any[])
    assignments = [assignment for (_, ex) in last(_statements(file; modules=true))
                   for assignment in (_assignment(ex),) if assignment !== nothing]
    selected = Set{Symbol}()
    changed = true
    while changed
        changed = false
        for (names, value) in assignments
            any(in(needed), names) && !all(in(selected), names) || continue
            union!(selected, names)
            union!(needed, names)
            _symbols!(needed, value)
            changed = true
        end
    end
    return selected
end

"""
    concretization_patterns(file; selection=false) -> Vector{String}

The source text of `file`'s top-level statements that analysis may evaluate: pure
assignments and definition guards, and with `selection`, the assignments a test driver's
run-time includes depend on. Each text is a JETLS concretization pattern that matches
exactly its statement.
"""
function concretization_patterns(file::String; selection::Bool=false)
    selected = selection ? include_selectors(file) : Set{Symbol}()
    text, statements = _statements(file; modules=true)
    known = Set{Symbol}()
    patterns = String[]
    for (node, ex) in statements
        assignment = _assignment(ex)
        if assignment !== nothing
            names, value = assignment
            if (_pure(value, known) || any(in(selected), names)) && !_wildcards(ex)
                push!(patterns, _source_text(node, text))
                union!(known, names)
            else
                setdiff!(known, names)
            end
        elseif _guard(ex, known) && !_wildcards(ex)
            push!(patterns, _source_text(node, text))
            _assigned!(known, ex)
            foreach(e -> union!(known, _bound_names(e)), _subexpressions(ex))
        else
            union!(known, _bound_names(ex))
        end
    end
    return patterns
end

# Test-driver preludes
# ====================
#
# A test file that its driver (`test/runtests.jl`) includes from a run-time loop is
# analyzed as its own unit after a prelude: the driver's imports and definitions, and only
# those global assignments that the test file or those definitions refer to, transitively.
# Selection logic such as `const TESTS = isempty(ARGS) ? ALL : ARGS` is left out, since
# nothing the test file uses depends on it. Statements keep their original source text, with
# `@__DIR__`, `@__FILE__` and relative include paths pinned to their original file.

function _macro_identifier(node::JS.SyntaxNode)
    JS.kind(node) == JS.K"macrocall" || return nothing
    name = first(JS.children(node))
    JS.kind(name) == JS.K"." && (name = last(JS.children(name)))
    JS.kind(name) == JS.K"macro_name" || return nothing
    identifier = first(JS.children(name))
    return identifier.data === nothing ? nothing : identifier.data.val
end

function _include_literal(node::JS.SyntaxNode)
    JS.kind(node) == JS.K"call" || return nothing
    children = JS.children(node)
    length(children) >= 2 || return nothing
    callee = first(children)
    JS.kind(callee) == JS.K"." && (callee = last(JS.children(callee)))
    callee.data !== nothing && callee.data.val === :include || return nothing
    path = last(children)
    JS.kind(path) == JS.K"string" && length(JS.children(path)) == 1 || return nothing
    literal = only(JS.children(path))
    JS.kind(literal) == JS.K"String" || return nothing
    return path => literal.data.val
end

"The source text of `node`, with locations that depend on its file pinned to `file`."
function _relocated(node::JS.SyntaxNode, text::String, file::String)
    edits = Pair{UnitRange{Int},String}[]
    function visit(n)
        macro_name = _macro_identifier(n)
        if macro_name in (:__DIR__, :__FILE__)
            return push!(edits, JS.byte_range(n) => repr(macro_name === :__DIR__ ? dirname(file) : file))
        end
        literal = _include_literal(n)
        if literal !== nothing && !isabspath(last(literal))
            push!(edits, JS.byte_range(first(literal)) => repr(normpath(dirname(file), last(literal))))
        end
        JS.is_leaf(n) || foreach(visit, JS.children(n))
    end
    visit(node)
    bytes = codeunits(text)
    io = IOBuffer()
    position = first(JS.byte_range(node))
    for (range, replacement) in sort!(edits; by=edit -> first(first(edit)))
        write(io, view(bytes, position:first(range)-1), replacement)
        position = last(range) + 1
    end
    write(io, view(bytes, position:last(JS.byte_range(node))))
    return String(take!(io))
end

function _driver_statements!(statements, file::String, target::String, seen::Set{String})
    file in seen && return statements
    push!(seen, file)
    text, nodes = _statements(file)
    bindings = Dict{Symbol,String}()
    for (node, ex) in nodes
        if _is_include(ex)
            path = _path(last(ex.args), file, bindings, Dict{String,String}())
            path === nothing && continue
            path = normpath(dirname(file), path)
            path != target && isfile(path) && _driver_statements!(statements, path, target, seen)
            continue
        end
        assignment = _assignment(ex)
        if assignment !== nothing
            names, value = assignment
            known = length(names) == 1 ? _path(value, file, bindings, Dict{String,String}()) : nothing
            known === nothing ? foreach(name -> delete!(bindings, name), names) : (bindings[only(names)] = known)
        end
        if ex isa Expr && (ex.head in (:using, :import) || _definition(ex) || assignment !== nothing)
            push!(statements, (; file, line=JS.source_line(node), ex, names=assignment === nothing ? Symbol[] : first(assignment),
                                 text=_relocated(node, text, file)))
        end
    end
    return statements
end

"""
    prelude(driver, target) -> String

Source text recreating the context `driver` establishes for `target`, which it includes
at run time: imports, definitions and the global assignments `target` transitively
refers to, also from files `driver` includes statically.
"""
function prelude(driver::String, target::String)
    statements = _driver_statements!(NamedTuple[], driver, target, Set{String}())
    needed = Set{Symbol}()
    pending, seen = [target], Set{String}()
    while !isempty(pending)
        file = pop!(pending)
        (file in seen || !isfile(file)) && continue
        push!(seen, file)
        _symbols!(needed, Meta.parseall(read(file, String); filename=file))
        append!(pending, (i.target for i in parse_source(file).includes if !isempty(i.target)))
    end
    selected = [isempty(statement.names) for statement in statements]
    for (statement, keep) in zip(statements, selected)
        keep && _symbols!(needed, statement.ex)
    end
    changed = true
    while changed
        changed = false
        for (i, statement) in pairs(statements)
            selected[i] && continue
            any(in(needed), statement.names) || continue
            selected[i] = changed = true
            _symbols!(needed, statement.ex)
        end
    end
    io = IOBuffer()
    for (statement, keep) in zip(statements, selected)
        keep && println(io, "#= ", statement.file, ":", statement.line, " =#\n", statement.text)
    end
    return String(take!(io))
end
