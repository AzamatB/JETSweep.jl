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

"""
Top-level statements of a file with their expressions and source text. `blocks` flattens
`begin` blocks, which JETLS matches against concretization patterns as single statements.
"""
function _statements(file::String; modules::Bool=false, blocks::Bool=true)
    text = read(file, String)
    tree = JS.parseall(JS.SyntaxNode, text; filename=file, ignore_errors=true)
    statements = Tuple{JS.SyntaxNode,Any}[]
    function flatten(node)
        kind = JS.kind(node)
        if kind == JS.K"toplevel" || (blocks && kind == JS.K"block")
            foreach(flatten, JS.children(node))
        elseif modules && kind == JS.K"module"
            foreach(flatten, JS.children(last(JS.children(node))))
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
        # Paths built by interpolation, as in `@eval using $name`, bind nothing known.
        names = Any[]
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
        return Symbol[name for name in names if name isa Symbol]
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
# Script analysis evaluates definitions, imports and includes but not assignments, so a
# definition or `include` that needs an assigned value stops it
# (`toplevel/missing-concretization`), and other code sees assigned values only as types.
# JETSweep lets JETLS evaluate the top-level statements that cannot have side effects:
# assignments of values built from literals, paths and pure functions of names already
# bound, and blocks and conditionals made only of these, definitions and imports. Values
# that depend on how the program is run (`ARGS`, `ENV`) are evaluated only where analysis
# needs them: in `include` arguments, definition signatures, and the conditions JETLS
# evaluates to define the closures in their branches. A test driver whose run-time includes
# are analyzed as their own units also evaluates whatever selects those files.

const _PURE_NAMES = Set([:nothing, :missing, :true, :false, :Inf, :NaN, :pi, :π, :ℯ])
"Names whose values depend on how the analyzed program is run."
const _PROCESS_NAMES = Set([:ARGS, :ENV])
const _PURE_CALLS = Set(Symbol.(split("""
    joinpath normpath dirname basename splitext splitdir splitpath relpath isabspath isfile isdir
    ispath readdir pkgdir pathof string repr * + - / // ^ % ÷ \\ div rem mod fld cld min max abs sqrt cbrt exp
    exp2 exp10 log log2 log10 sin cos tan hypot round floor ceil trunc length Dict Set Pair => :
    range collect Tuple NamedTuple tuple Symbol Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32
    UInt64 Float16 Float32 Float64 Bool String Char BigInt BigFloat Rational Complex VersionNumber Vector Matrix
    Regex zero one typemax typemin == != === !== < <= > >= ! isempty first last reverse sort unique
    vcat hcat keys values pairs merge union intersect setdiff lowercase uppercase titlecase
    uppercasefirst lowercasefirst split rsplit strip lstrip rstrip chomp chop startswith endswith
    occursin contains replace join lpad rpad repeat parse tryparse match something isnothing
    ismissing identity sum prod maximum minimum extrema in ∈ ∉ get haskey getindex isodd iseven
    deg2rad rad2deg map filter any all count findfirst findall enumerate zip eltype typeof isa
    iswindows islinux isapple isunix isbsd""")))
"Pure functions that call a function argument, which must then be pure as well."
const _HIGHER_ORDER = Set([:map, :filter, :any, :all, :count, :findfirst, :findall, :sum, :prod, :maximum,
                           :minimum, :extrema, :sort, :unique])
const _PURE_MACROS = Set(["@__DIR__", "@__FILE__", "@__MODULE__", "@__LINE__", "@r_str", "@raw_str", "@s_str",
                          "@v_str", "@big_str", "@isdefined"])

"What a file's top-level names are, as far as purity depends on them."
struct _Scope
    "Names bound to values evaluation reproduces: by pure assignments and module imports, so far."
    known::Set{Symbol}
    "Names of the file's functions and types and of imported bindings: calling them runs other code."
    opaque::Set{Symbol}
    "Names the file binds anywhere, which hide Base's."
    shadowed::Set{Symbol}
end

_within_scope(scope::_Scope, names) =
    _Scope(union(scope.known, names), setdiff(scope.opaque, names), scope.shadowed)

"Base's constant types, functions, modules and immutable values."
function _pure_global(name::Symbol)
    isdefined(Base, name) && isconst(Base, name) && !Base.isdeprecated(Base, name) || return false
    value = getglobal(Base, name)
    return value isa Union{Type,Function,Module,String,Symbol,VersionNumber} || isbits(value)
end

function _pure_callee(f, scope::_Scope)
    f isa Symbol && return (f in _PURE_CALLS || f === :isdefined) && !(f in scope.shadowed)
    f isa Expr || return false
    f.head === :curly && return _pure_callee(first(f.args), scope) && all(arg -> _pure_type(arg, scope), f.args[2:end])
    return f.head === :. && first(f.args) in (:Base, :Sys) && Symbol(_name(f)) in _PURE_CALLS
end

"A type parameter: the file's own types count, since naming a type runs no code."
_pure_type(ex, scope::_Scope) =
    ex isa Symbol ? ex in scope.opaque || _pure(ex, scope) :
    ex isa Expr && ex.head in (:curly, :<:, :>:) ? all(arg -> _pure_type(arg, scope), ex.args) : _pure(ex, scope)

"Whether evaluating `ex` is free of side effects, reading only literals, Base and names `scope` knows."
function _pure(ex, scope::_Scope)
    ex isa Union{Number,String,Char,Nothing,LineNumberNode} && return true
    ex isa QuoteNode && return ex.value isa Symbol
    if ex isa Symbol
        ex in scope.known && return true
        (ex in scope.opaque || ex in scope.shadowed) && return false
        return ex in _PURE_NAMES || ex in _PROCESS_NAMES || _pure_global(ex)
    end
    ex isa Expr || return false
    pure(args) = all(arg -> _pure(arg, scope), args)
    head = ex.head
    head === :macrocall && return _macro_name(ex) in _PURE_MACROS &&
        all(arg -> arg isa Union{Symbol,String,LineNumberNode}, ex.args[2:end])
    head in (:tuple, :vect, :vcat, :hcat, :row, :nrow, :ncat, :parameters, :string, :&&, :||, :if, :elseif,
             :block, :comparison, :ref, :comprehension, :flatten) && return pure(ex.args)
    head === :typed_comprehension && return _pure_type(first(ex.args), scope) && pure(ex.args[2:end])
    head === :curly && return all(arg -> _pure_type(arg, scope), ex.args)
    head in (:kw, :(=)) && return first(ex.args) isa Symbol && _pure(last(ex.args), scope)
    head === :-> && return _pure_function(ex, scope)
    head === :generator && return _pure_generator(ex, scope)
    if head === :.
        length(ex.args) == 2 || return false
        base, field = ex.args
        # Reading a global of a known module is pure too, as in `Sys.KERNEL` or `Package.VERSION`;
        # globals of modules the analyzed code defines may be left unevaluated.
        field isa QuoteNode && return _pure(base, scope)
        # `f.(x)` broadcasts `f`
        return field isa Expr && field.head === :tuple && _pure_callee(base, scope) && pure(field.args)
    end
    head === :call || return false
    callee = first(ex.args)
    _pure_callee(callee, scope) || return false
    arguments = ex.args[2:end]
    if callee in _HIGHER_ORDER
        # A function argument must be pure itself: not the file's or a package's function.
        position = findfirst(arg -> !(arg isa Expr && arg.head === :parameters), arguments)
        function_argument = position === nothing ? nothing : arguments[position]
        function_argument isa Expr && function_argument.head === :. && return false
    end
    return pure(arguments)
end

function _pure_function(ex::Expr, scope::_Scope)
    parameters = first(ex.args)
    parameters isa Expr && parameters.head === :tuple || (parameters = Expr(:tuple, parameters))
    names = Symbol[]
    for parameter in parameters.args
        if parameter isa Expr && parameter.head === :(::) && length(parameter.args) == 2
            _pure_type(last(parameter.args), scope) || return false
            parameter = first(parameter.args)
        end
        parameter isa Symbol || return false
        push!(names, parameter)
    end
    return _pure(last(ex.args), _within_scope(scope, names))
end

function _pure_generator(ex::Expr, scope::_Scope)
    body, specs = first(ex.args), ex.args[2:end]
    condition = nothing
    if length(specs) == 1 && only(specs) isa Expr && only(specs).head === :filter
        condition, specs = first(only(specs).args), only(specs).args[2:end]
    end
    names = Set{Symbol}()
    for spec in specs
        spec isa Expr && spec.head === :(=) && _pure(last(spec.args), scope) || return false
        _symbols!(names, first(spec.args))
    end
    inner = _within_scope(scope, names)
    return _pure(body, inner) && (condition === nothing || _pure(condition, inner))
end

"Names a top-level statement binds globally: assignments outside local scopes, definitions and imports."
function _binds!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    assignment = _assignment(ex)
    if assignment !== nothing
        union!(names, first(assignment))
    elseif ex.head in _UPDATES
        union!(names, _assignees(first(ex.args)))
    elseif ex.head in (:block, :toplevel, :if, :elseif, :&&, :||)
        foreach(arg -> _binds!(names, arg), ex.args)
    elseif ex.head === :macrocall
        union!(names, _bound_names(ex))
        foreach(arg -> _binds!(names, arg), ex.args)
    else
        union!(names, _bound_names(ex))
    end
    return names
end

"""
Names that `ex` may mutate, or rebind from a local scope, invisibly to a later evaluation:
arguments of `!` functions, objects of indexed, field and broadcast assignments, and names
assigned as `global` in functions and loops.
"""
function _mutated!(names::Set{Symbol}, ex, scoped::Bool=false)
    ex isa Expr || return names
    ex.head in (:quote, :inert) && return names
    root(ex) = ex isa Symbol ? ex : ex isa Expr && ex.head in (:ref, :.) && !isempty(ex.args) ? root(first(ex.args)) : nothing
    target = nothing
    if ex.head === :call && length(ex.args) >= 2 && endswith(_name(first(ex.args)), '!')
        position = findfirst(arg -> !(arg isa Expr && arg.head === :parameters), ex.args[2:end])
        position === nothing || (target = root(ex.args[position+1]))
    elseif (ex.head === :(=) || ex.head in _UPDATES) && first(ex.args) isa Expr && first(ex.args).head in (:ref, :.)
        target = root(first(ex.args))
    elseif ex.head === :.=
        target = root(first(ex.args))
    elseif ex.head === :global && scoped
        foreach(arg -> _assigned!(names, arg), ex.args)
    end
    target === nothing || push!(names, target)
    scoped = scoped || _method(ex) || ex.head in (:let, :for, :while, :try)
    foreach(arg -> _mutated!(names, arg, scoped), ex.args)
    return names
end

"""
The names known after evaluating the top-level statement `ex`, if evaluating it is free of
side effects: a pure assignment, or a block or conditional made of those, definitions and
imports. `nothing` otherwise. `bound` holds the names earlier statements bind.
"""
function _evaluable(ex, scope::_Scope, bound::Set{Symbol})
    assignment = _assignment(ex)
    if assignment !== nothing
        names, value = assignment
        return _pure(value, scope) ? names : nothing
    end
    ex isa Expr || return nothing
    if ex.head === :block
        inner = _Scope(copy(scope.known), copy(scope.opaque), scope.shadowed)
        known = Symbol[]
        for statement in ex.args
            statement isa LineNumberNode && continue
            names = _member(statement, inner, bound)
            names === nothing && return nothing
            union!(inner.known, names)
            _define!(inner, statement)
            append!(known, names)
        end
        return known
    elseif ex.head in (:if, :elseif)
        _pure(first(ex.args), scope) || return nothing
        branches = [_member(branch, scope, bound) for branch in ex.args[2:end]]
        any(isnothing, branches) && return nothing
        # Evaluation takes the branch the program takes. Names that branch may leave unbound
        # count only if nothing bound them before.
        complete = length(ex.args) == 3 ? intersect(branches...) : Symbol[]
        return union(complete, setdiff(union(branches...), bound))
    end
    return nothing
end

"Like `_evaluable`, for a statement inside a block or branch, where definitions and imports may also appear."
function _member(ex, scope::_Scope, bound::Set{Symbol})
    ex isa LineNumberNode && return Symbol[]
    ex isa Expr && ex.head === :module && return nothing
    ex isa Expr && (ex.head in (:using, :import) || _definition(ex)) && return Symbol[]
    return _evaluable(ex, scope, bound)
end

"Names of the functions, types, modules and imported bindings a statement defines."
function _definitions(ex)
    ex isa Expr || return Set{Symbol}()
    _assignment(ex) === nothing || return Set{Symbol}()
    ex.head in (:block, :if, :elseif) && return union(Set{Symbol}(), (_definitions(arg) for arg in ex.args)...)
    return Set{Symbol}(_bound_names(ex))
end

"""
Names a statement binds to whole modules of packages, as `using A`, `import A.B` and
`import A as B` do. Modules the analyzed code defines, which `using .A` names, are left out.
"""
function _modules(ex)
    names = Set{Symbol}()
    ex isa Expr || return names
    if ex.head in (:using, :import)
        for path in ex.args
            path isa Expr && path.head === :as && (path = Expr(:., first(path.args).args..., last(path.args)))
            path isa Expr && path.head === :. && !isempty(path.args) && first(path.args) !== :. &&
                last(path.args) isa Symbol && push!(names, last(path.args))
        end
    elseif ex.head in (:block, :if, :elseif, :macrocall)
        foreach(arg -> union!(names, _modules(arg)), ex.args)
    end
    return names
end

"Record what `ex` defines: modules are values evaluation can read, other definitions are opaque."
function _define!(scope::_Scope, ex)
    modules = _modules(ex)
    union!(scope.known, modules)
    union!(scope.opaque, setdiff(_definitions(ex), modules))
    return scope
end

const _TEST_MACROS = Set(["@test", "@test_broken", "@test_skip", "@test_throws", "@test_logs", "@test_warn",
                          "@test_nowarn", "@test_deprecated", "@inferred"])

"Whether a method definition is a closure: an anonymous function or a `do` block."
_closure(ex::Expr) = ex.head === :-> ||
    (ex.head === :function && first(ex.args) isa Expr && first(ex.args).head === :tuple)

"""
Add the names whose values JETLS evaluates when it analyzes the top-level statement `ex`:
arguments of `include` and `eval` calls, signatures of definitions, the control flow around
these and around imports, and the conditions of branches that define closures, which JETLS
evaluates to define them; with `includes`, only those of `include` calls. Assignments in
`ex` that these names depend on count too.
"""
function _reads!(needed::Set{Symbol}, ex; includes::Bool=false)
    direct = Set{Symbol}()
    locals = Pair{Set{Symbol},Set{Symbol}}[]
    needs!(parts, controls) = (foreach(part -> _symbols!(direct, part), parts); foreach(c -> _symbols!(direct, c), controls))
    function visit(ex, controls::Vector{Any}, branches::Vector{Any})
        ex isa Expr || return
        head = ex.head
        if head in (:quote, :inert, :module)
            return
        elseif head === :macrocall
            name = _macro_name(ex)
            name in _TEST_MACROS && return     # JETLS outlines their closures into thunks
            name == "@eval" && return includes || needs!(ex.args, controls)
            # `@static` evaluates its condition when it expands.
            !includes && name == "@static" && last(ex.args) isa Expr && last(ex.args).head === :if &&
                needs!(Any[first(last(ex.args).args)], controls)
            foreach(arg -> visit(arg, controls, branches), ex.args[2:end])
        elseif _is_include(ex)
            needs!(ex.args[2:end], controls)
        elseif head === :call && _name(first(ex.args)) == "eval"
            includes || needs!(ex.args[2:end], controls)
        elseif _method(ex)
            includes || (_closure(ex) ? needs!(branches, Any[]) : needs!(Any[first(ex.args)], controls))
        elseif head in (:struct, :abstract, :primitive)
            includes || needs!(Any[ex], controls)
        elseif head in (:using, :import)
            includes || needs!(Any[], controls)
        elseif head in (:if, :elseif, :&&, :||)
            condition = first(ex.args)
            visit(condition, controls, branches)
            foreach(arg -> visit(arg, [controls; condition], [branches; condition]), ex.args[2:end])
        elseif head in (:for, :while)
            visit(first(ex.args), controls, branches)
            visit(last(ex.args), [controls; first(ex.args)], branches)
        else
            !includes && head in (:generator, :comprehension, :typed_comprehension, :do) && needs!(branches, Any[])
            if head === :(=) && !_signature(first(ex.args))
                push!(locals, _symbols(first(ex.args)) => union(_symbols(last(ex.args)), (_symbols(c) for c in controls)...))
            end
            foreach(arg -> visit(arg, controls, branches), ex.args)
        end
    end
    visit(ex, Any[], Any[])
    changed = true
    while changed
        changed = false
        for (assigned, dependencies) in locals
            (isdisjoint(assigned, direct) || issubset(dependencies, direct)) && continue
            union!(direct, dependencies)
            changed = true
        end
    end
    return union!(needed, direct)
end

"""
Indices of the statements that analysis may evaluate. Run-dependent statements are evaluated
only where needed, or where JETLS evaluates part of them anyway; with `selection`, so are
impure assignments that `include` calls need. `excluded` statements are not.
"""
function _concretized(expressions::Vector{Any}, excluded::Set{Int}, selection::Bool)
    shadowed = Set{Symbol}()
    foreach(ex -> (_assigned!(shadowed, ex); union!(shadowed, _definitions(ex))), expressions)
    scope = _Scope(Set{Symbol}(), Set{Symbol}(), shadowed)
    variable = setdiff(_PROCESS_NAMES, shadowed)
    bound = Set{Symbol}()
    selected = Set{Int}()
    # Statements to evaluate where needed: their names, what they read, and whether pure.
    deferred = Tuple{Int,Vector{Symbol},Set{Symbol},Bool}[]
    needed, selectors = Set{Symbol}(), Set{Symbol}()
    for (i, ex) in pairs(expressions)
        binds = _binds!(Set{Symbol}(), ex)
        assignment = _assignment(ex)
        reads = assignment === nothing ? _symbols(ex) : _symbols(last(assignment))
        known = i in excluded ? nothing : _evaluable(ex, scope, bound)
        setdiff!(scope.known, binds)
        if known === nothing
            if selection
                !(i in excluded) && assignment !== nothing && push!(deferred, (i, first(assignment), reads, false))
                _reads!(selectors, ex; includes=true)
            end
            _reads!(needed, ex)
            setdiff!(variable, binds)
        elseif isdisjoint(reads, variable)
            push!(selected, i)
            union!(scope.known, known)
            setdiff!(variable, binds)
        else
            # JETLS evaluates part of a statement anyway when it defines a closure in a
            # branch, and then not the closure in the other branch: evaluating it whole is better.
            evaluated = _reads!(Set{Symbol}(), ex)
            isempty(evaluated) ? push!(deferred, (i, collect(binds), reads, true)) : push!(selected, i)
            union!(needed, evaluated)
            union!(scope.known, known)
            union!(variable, binds)
        end
        _define!(scope, ex)
        setdiff!(scope.known, _mutated!(Set{Symbol}(), ex))
        union!(bound, binds)
    end
    changed = true
    while changed
        changed = false
        for (i, names, reads, pure) in deferred
            !(i in selected) && any(name -> name in selectors || pure && name in needed, names) || continue
            push!(selected, i)
            union!(pure ? needed : selectors, reads)
            changed = true
        end
    end
    return selected
end

_binding(name) = name isa Symbol && (name === :_ || occursin(r"[^_]_(_str)?$", String(name)))
_slurp(name) = name isa Symbol && (name === :__ || occursin(r"[^_]__$", String(name)))

function _normalise(ex)
    while ex isa Expr && ex.head === :block
        statements = filter(arg -> !(arg isa LineNumberNode), ex.args)
        length(statements) == 1 || break
        ex = only(statements)
    end
    ex isa QuoteNode && return Expr(:quote, ex.value)
    ex isa Expr && ex.head === :inert && return Expr(:quote, only(ex.args))
    ex isa Expr && ex.head === :kw && return Expr(:(=), ex.args...)
    return ex
end

"""
Whether MacroTools may match pattern `pattern` to `ex`, as JETLS matches concretization
patterns: names such as `x_` match any expression and names such as `@__DIR__` any number
of them. Bindings that must repeat are not checked, so this may claim a match that is none.
"""
function _may_match(pattern, ex)
    pattern, ex = _normalise(pattern), _normalise(ex)
    (_binding(pattern) || _slurp(pattern)) && return true
    pattern isa Expr && ex isa Expr || return pattern == ex
    pattern.head === :block && ex.head !== :block && (ex = Expr(:block, ex))
    ex.head === :block && pattern.head !== :block && (pattern = Expr(:block, pattern))
    pattern.head === ex.head || return false
    patterns = filter(arg -> !(arg isa LineNumberNode), pattern.args)
    arguments = filter(arg -> !(arg isa LineNumberNode), ex.args)
    any(_slurp, patterns) && return true
    return length(patterns) == length(arguments) && all(_may_match(p, a) for (p, a) in zip(patterns, arguments))
end

"""
    concretization_patterns(file; selection=false) -> Vector{String}

The source text of the top-level statements of `file` that analysis may evaluate, each a
JETLS concretization pattern. With `selection`, also the assignments its `include` calls
depend on, which a test driver whose run-time includes are analyzed separately evaluates
to get past them.
"""
function concretization_patterns(file::String; selection::Bool=false)
    text, statements = _statements(file; modules=true, blocks=false)
    expressions = Any[last(statement) for statement in statements]
    excluded = Set{Int}()
    while true
        selected = _concretized(expressions, excluded, selection)
        # A pattern selects every statement of its file that it matches.
        conflicts = filter(i -> any(j -> !(j in selected) && _may_match(expressions[i], expressions[j]),
                                    eachindex(expressions)), selected)
        isempty(conflicts) && return [_source_text(first(statements[i]), text) for i in sort!(collect(selected))]
        union!(excluded, conflicts)
    end
end

# Test-driver preludes
# ====================
#
# A test file that its driver (`test/runtests.jl`) includes from a run-time loop is
# analyzed as its own unit after a prelude: the driver's imports and definitions, and only
# those global assignments that the test file or those definitions refer to, transitively.
# Selection logic such as `const TESTS = isempty(ARGS) ? ALL : ARGS` is left out, since
# nothing the test file uses depends on it. Statements keep their original source text, with
# `@__DIR__`, `@__FILE__` and relative include paths pinned to their original file. Pure
# assignments are wrapped in `@eval`, which analysis always evaluates, since concretization
# patterns cannot apply to the generated file.

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

struct _DriverStatement
    file::String
    line::Int
    ex::Any
    "The names an assignment binds; empty for imports and definitions."
    names::Vector{Symbol}
    text::String
end

"Include calls in `ex` that run when it does, outside function bodies."
function _nested_includes!(includes::Vector{Expr}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert, :module)) && !_method(ex) || return includes
    _is_include(ex) ? push!(includes, ex) : foreach(arg -> _nested_includes!(includes, arg), ex.args)
    return includes
end

function _driver_statements!(statements::Vector{_DriverStatement}, file::String, next::String, seen::Set{String})
    file in seen && return statements
    push!(seen, file)
    text, nodes = _statements(file)
    bindings = Dict{Symbol,String}()
    for (node, ex) in nodes
        # Top-level includes set up context, as helpers do. Included files run at top level
        # wherever the call is, but other includes are test files, except nested drivers
        # included inside a `@testset`, say.
        for include in _nested_includes!(Expr[], ex)
            path = _path(last(include.args), file, bindings, Dict{String,String}())
            path === nothing && continue
            path = normpath(dirname(file), path)
            (_is_include(ex) || basename(path) == "runtests.jl") && path != next && isfile(path) &&
                _driver_statements!(statements, path, next, seen)
        end
        _is_include(ex) && continue
        assignment = _assignment(ex)
        if assignment !== nothing
            names, value = assignment
            known = length(names) == 1 ? _path(value, file, bindings, Dict{String,String}()) : nothing
            known === nothing ? foreach(name -> delete!(bindings, name), names) : (bindings[only(names)] = known)
        end
        if ex isa Expr && (ex.head in (:using, :import) || _definition(ex) || assignment !== nothing)
            push!(statements, _DriverStatement(file, JS.source_line(node), ex,
                                               assignment === nothing ? Symbol[] : first(assignment),
                                               _relocated(node, text, file)))
        end
    end
    return statements
end

"""
    prelude(drivers, target) -> String

Source text recreating the context that `drivers`, outermost first, establish for `target`,
which the last of them includes at run time: imports, definitions and the global
assignments `target` transitively refers to, also from files the drivers include statically.
"""
function prelude(drivers::Vector{String}, target::String)
    statements = _DriverStatement[]
    seen = Set{String}()
    for (i, driver) in pairs(drivers)
        _driver_statements!(statements, driver, i < length(drivers) ? drivers[i+1] : target, seen)
    end
    needed = Set{Symbol}()
    pending, visited = [target], Set{String}()
    while !isempty(pending)
        file = pop!(pending)
        (file in visited || !isfile(file)) && continue
        push!(visited, file)
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
    statements = statements[selected]
    evaluated = _concretized(Any[statement.ex for statement in statements], Set{Int}(), false)
    io = IOBuffer()
    for (i, statement) in pairs(statements)
        println(io, "#= ", statement.file, ":", statement.line, " =#")
        println(io, i in evaluated && !isempty(statement.names) ? "@eval " : "", statement.text)
    end
    return String(take!(io))
end
