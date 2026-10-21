# Static source facts. Parsing never executes user code; anything that depends on run-time
# values stays unresolved and is reported as such.

const JS = Base.JuliaSyntax

"An `include` call: its statically resolved target, or `\"\"` when only known at run time."
struct Include
    target::String
    line::Int
    "Whether analysis follows the call: JETLS skips includes inside function bodies."
    followed::Bool
    "How many `module` blocks of its file enclose the call."
    depth::Int
end
Include(target::String, line::Int, followed::Bool) = Include(target, line, followed, 0)

"The static facts `parse_source` finds in a file."
struct Syntax
    includes::Vector{Include}
    "Parse failures and includes that cannot be resolved statically."
    notes::Vector{String}
    "The packages that `using` and `import` statements load, by name."
    imports::Vector{String}
    "The paths top-level constants name at the end of the file, which includes can use."
    bindings::Dict{Symbol,String}
    "The modules it defines, by name."
    modules::Vector{String}
end
Syntax(includes::Vector{Include}, notes::Vector{String}, imports::Vector{String}=String[]) =
    Syntax(includes, notes, imports, Dict{Symbol,String}(), String[])

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

"What a command literal, in backticks, interpolates; `nothing` for other expressions."
function _command(ex)
    _macro_name(ex) == "@cmd" && last(ex.args) isa String || return nothing
    return try Base.shell_parse(last(ex.args); special=Base.shell_special)[1] catch; nothing end
end

_symbols!(names::Set{Symbol}, ex::Symbol) = push!(names, ex)
_symbols!(names::Set{Symbol}, ex::Expr) =
    (foreach(arg -> _symbols!(names, arg), something(_command(ex), ex).args); names)
_symbols!(names::Set{Symbol}, ex::QuoteNode) = _symbols!(names, ex.value)
_symbols!(names::Set{Symbol}, ::Any) = names
_symbols(ex) = _symbols!(Set{Symbol}(), ex)

"""
Evaluate a path expression built from literals, `@__DIR__`, `@__FILE__` and path calls,
`pkgdir(Name)` and `pathof(Name)` among them for the packages `packages` names.
"""
function _path(ex, file::String, bindings::Dict{Symbol,String}, packages::Dict{String,Project})
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
    if name in ("pkgdir", "pathof")
        package = length(ex.args) >= 2 ? get(packages, _name(ex.args[2]), nothing) : nothing
        package === nothing && return nothing
        name == "pathof" && return length(ex.args) == 2 && !isempty(package.entry) ? package.entry : nothing
        parts = [_path(arg, file, bindings, packages) for arg in ex.args[3:end]]
        return all(part -> part isa String, parts) ? joinpath(package.dir, parts...) : nothing
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
function _rebind!(bindings::Dict{Symbol,String}, ex::Expr, file::String, packages::Dict{String,Project})
    lhs = first(ex.args)
    if ex.head === :(=) && lhs isa Symbol
        value = _path(last(ex.args), file, bindings, packages)
        value === nothing ? delete!(bindings, lhs) : (bindings[lhs] = value)
    elseif ex.head === :(=) || ex.head in _UPDATES
        foreach(name -> delete!(bindings, name), _symbols(lhs))
    end
    return bindings
end

_assigned!(names::Set{Symbol}, ::Any) = names
function _assigned!(names::Set{Symbol}, ex::Expr)
    (ex.head === :(=) || ex.head in _UPDATES) && !_signature(first(ex.args)) && _symbols!(names, first(ex.args))
    foreach(arg -> _assigned!(names, arg), ex.args)
    return names
end

"Names that iteration specifications or `let` bindings introduce."
_loop_names(spec) = spec isa Expr && spec.head in (:(=), :block, :filter) ?
    (spec.head === :(=) ? _symbols(first(spec.args)) : mapreduce(_loop_names, union, spec.args; init=Set{Symbol}())) :
    (spec isa Symbol ? Set([spec]) : Set{Symbol}())

"What `parse_source` has found in a file so far, and the line it has reached."
mutable struct _SourceFacts
    const file::String
    const packages::Dict{String,Project}
    const exports::Dict{String,Dict{Symbol,String}}
    const includes::Vector{Include}
    const notes::Vector{String}
    const imports::Vector{String}
    const modules::Vector{String}
    line::Int
end

"Add what `ex` includes, imports and defines to `facts`; `bindings` are the path constants it sees."
function _source_facts!(facts::_SourceFacts, ex, bindings::Dict{Symbol,String}, followed::Bool, depth::Int=0)
    ex isa LineNumberNode && (facts.line = ex.line; return)
    ex isa Expr || return
    (; file, packages, exports, includes, notes, imports, modules) = facts
    head = ex.head
    if head in (:error, :incomplete)
        push!(notes, "$file:$(facts.line): cannot be parsed")
        return
    elseif head === :quote
        return
    elseif head in (:using, :import)
        for path in ex.args
            path isa Expr && path.head in (:(:), :as) && (path = first(path.args))
            path isa Expr && path.head === :. && !isempty(path.args) && first(path.args) isa Symbol &&
                first(path.args) !== :. && push!(imports, String(first(path.args)))
        end
        return
    elseif _is_include(ex)
        target = _path(last(ex.args), file, bindings, packages)
        if target === nothing
            push!(notes, "$file:$(facts.line): include target is only known at run time")
            push!(includes, Include("", facts.line, followed, depth))
        else
            target = normpath(dirname(file), target)
            push!(includes, Include(target, facts.line, followed, depth))
            merge!(bindings, get(exports, target, Dict{Symbol,String}()))
        end
        return
    elseif _method(ex)
        # Parameters shadow outer bindings; the body is analyzed, never run, at top level.
        body = copy(bindings)
        foreach(name -> delete!(body, name), _symbols(first(ex.args)))
        foreach(arg -> _source_facts!(facts, arg, body, false, depth), ex.args[2:end])
        return
    elseif head === :module
        ex.args[2] isa Symbol && push!(modules, String(ex.args[2]))
        _source_facts!(facts, last(ex.args), Dict{Symbol,String}(), followed, depth + 1)
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
    foreach(arg -> _source_facts!(facts, arg, inner, followed, depth), ex.args)
    scoped && foreach(name -> delete!(bindings, name), _assigned!(Set{Symbol}(), ex))
    return
end

"""
    parse_source(file, packages=Dict(); exports=Dict()) -> Syntax

Find the `include` calls of `file`. `packages` maps package names to their projects,
which resolves `pkgdir(Name)` and `pathof(Name)` paths; `exports` maps files to the path
constants they define, which code after including them can use.
"""
function parse_source(file::String, packages::Dict{String,Project}=Dict{String,Project}();
                      exports::Dict{String,Dict{Symbol,String}}=Dict{String,Dict{Symbol,String}}())
    includes, notes, imports, modules = Include[], String[], String[], String[]
    tree = try
        Meta.parseall(read(file, String); filename=file)
    catch err
        return Syntax(includes, ["$file: cannot be read: $(sprint(showerror, err))"])
    end
    top = Dict{Symbol,String}()
    _source_facts!(_SourceFacts(file, packages, exports, includes, notes, imports, modules, 1), tree, top, true)
    return Syntax(unique!(includes), unique!(notes), unique!(imports), top, unique!(modules))
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
    return text, _flatten!(Tuple{JS.SyntaxNode,Any}[], tree; modules, blocks)
end

"The children of `node`, none for a leaf."
function _children(node::JS.SyntaxNode)
    children = JS.children(node)
    return children === nothing ? JS.SyntaxNode[] : children
end

"The value of the leaf `node`, an identifier's name or a literal's value, if it has one."
_value(node::JS.SyntaxNode) = (data = node.data; data === nothing ? nothing : data.val)

"Push the statements `node` holds, with their expressions, onto `statements`."
function _flatten!(statements::Vector{Tuple{JS.SyntaxNode,Any}}, node::JS.SyntaxNode; modules::Bool=false,
                   blocks::Bool=true)
    kind = JS.kind(node)
    if kind == JS.K"toplevel" || (blocks && kind == JS.K"block")
        foreach(child -> _flatten!(statements, child; modules, blocks), _children(node))
    elseif modules && kind == JS.K"module"
        foreach(child -> _flatten!(statements, child; modules, blocks), _children(last(_children(node))))
    elseif kind != JS.K"error"
        ex = try
            Expr(node)
        catch
            nothing
        end
        ex === nothing || push!(statements, (node, ex))
    end
    return statements
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

"""
Whether `ex` is a conditional, plain or `@static`, whose branches only define, import and
assign, as definitions that depend on the Julia version are.
"""
function _conditional_definitions(ex)
    ex isa Expr || return false
    _macro_name(ex) == "@static" && return _conditional_definitions(last(ex.args))
    ex.head in (:if, :elseif) || return false
    return all(_definition_member, ex.args[2:end])
end

"Whether `ex` can stand in a branch of `_conditional_definitions`. A string there is no docstring, nor anything else."
_definition_member(ex) = ex isa Union{LineNumberNode,String} || ex isa Expr &&
    (ex.head in (:using, :import) || _definition(ex) || _assignment(ex) !== nothing ||
     _conditional_definitions(ex) || (ex.head === :block && all(_definition_member, ex.args)))

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
# Script analysis evaluates definitions, imports, includes and the deprecations of bindings,
# as `@deprecate_binding` declares them, but not assignments, so any of these that needs an
# assigned value stops it (`toplevel/missing-concretization`), and other code sees assigned
# values only as types.
# JETSweep lets JETLS evaluate the top-level statements that cannot have side effects:
# assignments of values built from literals, paths and pure functions of names already
# bound, and blocks and conditionals made only of these, definitions and imports. Values
# that depend on how and where the program runs (`ARGS`, `ENV`, `PROGRAM_FILE`, its
# directory and the files there) are evaluated
# only where analysis needs them: in `include` and `eval` arguments, definition signatures,
# `@deprecate_binding` messages, and the conditions JETLS evaluates to define the closures in
# their branches, to import or to deprecate.
# Since JETLS always evaluates `include` and `eval` calls, whatever their arguments need is
# evaluated too, pure or not, as a test driver's selection of the files it includes, and so
# are the conditions that decide whether they run, also those of early exits such as
# `file in SKIPPED && continue`.

const _PURE_NAMES = Set([:nothing, :missing, :true, :false, :Inf, :NaN, :pi, :π, :ℯ])
"Names whose values depend on how the analyzed program is run."
const _PROCESS_NAMES = Set([:ARGS, :ENV, :PROGRAM_FILE])
"Pure functions whose values depend on where the program runs: its directory and files."
const _RUN_DEPENDENT = Set([:abspath, :realpath, :pwd, :readdir, :read, :readlines, :readchomp, :parsefile])
const _PURE_CALLS = Set(Symbol.(split("""
    joinpath normpath dirname basename splitext splitdir splitpath relpath isabspath isfile isdir
    ispath readdir read readlines readchomp parseall parsefile abspath realpath pwd pkgdir pathof string repr * + - / // ^ % ÷ \\ div rem mod fld cld min max abs sqrt cbrt exp
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

"""
A constant of `mod` that evaluation can read: a type, module or immutable value, or a
function among `_PURE_CALLS`, since a pure function such as `map` may call it.
"""
function _pure_global(name::Symbol, mod::Module=Base)
    isdefined(mod, name) && isconst(mod, name) && !Base.isdeprecated(mod, name) || return false
    value = getglobal(mod, name)
    value isa Function && return name in _PURE_CALLS
    return value isa Union{Type,Module,String,Symbol,VersionNumber} || isbits(value)
end

function _pure_callee(f, scope::_Scope)
    f isa Symbol && return (f in _PURE_CALLS || f === :isdefined) && !(f in scope.shadowed)
    f isa Expr || return false
    f.head === :curly && return _pure_callee(first(f.args), scope) && all(arg -> _pure_type(arg, scope), f.args[2:end])
    return f.head === :. && first(f.args) in (:Base, :Sys, :Meta, :TOML) && Symbol(_name(f)) in _PURE_CALLS
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
        if field isa QuoteNode
            base in (:Base, :Core, :Sys, :Meta) && !(base in scope.shadowed) &&
                return _pure_global(field.value, getglobal(Base, base))
            return _pure(base, scope)
        end
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
        _macro_name(ex) == "@static" && foreach(arg -> _binds!(names, arg), ex.args)
    else
        union!(names, _bound_names(ex))
    end
    return names
end

"The name an indexed or field expression starts from, as `a` of `a.b[i]`, or `nothing`."
_mutation_root(ex) = ex isa Symbol ? ex :
    ex isa Expr && ex.head in (:ref, :.) && !isempty(ex.args) ? _mutation_root(first(ex.args)) : nothing

"""
Names that `ex` may mutate, or rebind from a local scope, invisibly to a later evaluation:
arguments of `!` functions, objects of indexed, field and broadcast assignments, and names
assigned as `global` in functions and loops.
"""
function _mutated!(names::Set{Symbol}, ex, scoped::Bool=false)
    ex isa Expr || return names
    ex.head in (:quote, :inert) && return names
    target = nothing
    if ex.head === :call && length(ex.args) >= 2 && endswith(_name(first(ex.args)), '!')
        position = findfirst(arg -> !(arg isa Expr && arg.head === :parameters), ex.args[2:end])
        position === nothing || (target = _mutation_root(ex.args[position+1]))
    elseif (ex.head === :(=) || ex.head in _UPDATES) && first(ex.args) isa Expr && first(ex.args).head in (:ref, :.)
        target = _mutation_root(first(ex.args))
    elseif ex.head === :.=
        target = _mutation_root(first(ex.args))
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

"Names assigned as `global` anywhere in `ex`, in functions too."
function _globals!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    ex.head === :global && foreach(arg -> arg isa Symbol ? push!(names, arg) : _assigned!(names, arg), ex.args)
    foreach(arg -> _globals!(names, arg), ex.args)
    return names
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
Names a statement binds to whole modules of packages, as `using A.B`, `import A` and
`import A as B` do; `import A.f` may bind a function. Modules the analyzed code defines,
which `using .A` names, are left out.
"""
function _modules(ex)
    names = Set{Symbol}()
    ex isa Expr || return names
    if ex.head in (:using, :import)
        for path in ex.args
            alias = nothing
            path isa Expr && path.head === :as && ((path, alias) = (first(path.args), last(path.args)))
            path isa Expr && path.head === :. && !isempty(path.args) && first(path.args) !== :. || continue
            ex.head === :using || length(path.args) == 1 || continue
            name = something(alias, last(path.args))
            name isa Symbol && push!(names, name)
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

const _OUTLINABLE = (:call, :ref, :., :parameters, :kw, :..., :block, :&&, :||, :if, :comparison, :tuple, :vect,
                     :vcat, :hcat, :ncat, :typed_vcat, :typed_hcat, :typed_ncat, :row, :nrow, :string, :curly, :(::),
                     :where)

"""
Whether `ex` must stay at top level: it includes or evaluates code, which JETLS follows
only there, or interpolates into quoted code, which runs where the quote stands.
"""
_stays(ex) = ex isa Expr && (ex.head === :$ ||
    (ex.head === :call && _name(first(ex.args)) in ("include", "include_string", "eval")) ||
    _macro_name(ex) == "@eval" || any(_stays, ex.args))

"""
Whether the analysis worker outlines the top-level expression `ex` into a function, as JET
does a `@test` expression, so that the closures it defines need no evaluated conditions: an
expression of calls and control flow, binding no names, that defines a function in a branch;
a local scope, a loop, `let` or `try` block or a test set, that defines a function under control
flow inside it; or a conditional of tests, which binds nothing either. Code that includes or
evaluates code stays at top level, as does what only top-level code may hold, and closures
whose parameters declare types. A generator's ranges stand outside its closure.
"""
function _outlined(ex)
    ex isa Expr || return false
    conditional = ex.head === :if && _binds_nothing(ex) && _controlled_function(ex)
    return (_thunk_safe(ex) && _conditional_function(ex) || _outlinable_scope(ex) || conditional) &&
        !_stays(ex) && !_typed_closure(ex) && !_toplevel_only(ex)
end

"Whether JET can analyze expression `ex` in a closure: one of calls and control flow, binding no names."
_thunk_safe(ex) = !(ex isa Expr) || ex.head in (:quote, :inert) || _anonymous(ex) ||
    (ex.head === :do && _thunk_safe(first(ex.args)) && _closure(last(ex.args))) ||
    (ex.head in _OUTLINABLE && all(_thunk_safe, ex.args))

"Whether `ex` defines an anonymous function, or a generator whose ranges JET can analyze in a closure."
_anonymous(ex) = _closure(ex) || ex isa Expr && (
    ex.head in (:comprehension, :flatten) && length(ex.args) == 1 ? _anonymous(only(ex.args)) :
    ex.head === :typed_comprehension ? _thunk_safe(first(ex.args)) && _anonymous(last(ex.args)) :
    ex.head === :generator && all(ex.args[2:end]) do spec
        specs = spec isa Expr && spec.head === :filter ? spec.args[2:end] : Any[spec]
        all(s -> s isa Expr && s.head === :(=) && _thunk_safe(last(s.args)), specs)
    end)

"Whether `ex` defines an anonymous function where it is evaluated conditionally, as JET decides for a test expression."
function _conditional_function(ex, conditional::Bool=false)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return false
    _anonymous(ex) && return conditional
    ex.head === :do && length(ex.args) == 2 &&
        return _conditional_function(first(ex.args), conditional) || conditional && _anonymous(last(ex.args))
    ex.head in (:&&, :||) && length(ex.args) == 2 &&
        return _conditional_function(first(ex.args), conditional) || _conditional_function(last(ex.args), true)
    ex.head === :if && !isempty(ex.args) &&
        return _conditional_function(first(ex.args), conditional) || any(b -> _conditional_function(b, true), ex.args[2:end])
    ex.head === :comparison &&
        return any(_conditional_function(arg, conditional || i >= 5) for (i, arg) in enumerate(ex.args))
    return any(arg -> _conditional_function(arg, conditional), ex.args)
end

const _TESTING_MACROS = union(_TEST_MACROS, Set(["@testset"]))
"Logging macros, which evaluate their arguments in a `let` block of their own."
const _LOGGING_MACROS = Set(["@debug", "@info", "@warn", "@error", "@logmsg"])

"""
Whether code binds nothing where it stands: tests and logging, whose bodies and arguments are
local scopes, but for values such as the exception `@test_throws` expects; loops, `let` and
`try` blocks; and calls and control flow of these, of values such as `@__DIR__` and of
expressions JET can analyze in a closure.
"""
_binds_nothing(ex) = !(ex isa Expr) || ex.head in (:quote, :inert) ||
    (ex.head === :macrocall ? any(names -> _macro_name(ex) in names, (_TESTING_MACROS, _LOGGING_MACROS, _PURE_MACROS)) :
     ex.head in (:block, :if, :elseif) ? all(_binds_nothing, ex.args) :
     ex.head in (:for, :while, :let, :try) || (ex.head in _OUTLINABLE && all(_binds_nothing, ex.args)) || _thunk_safe(ex))

"""
Whether `ex` is a loop, `let` or `try` block or test set that defines a function under control
flow inside it. A function directly in a local scope needs none to be defined, nor does one in
a `try` block of it.
"""
_outlinable_scope(ex::Expr) = (ex.head in (:for, :while, :let, :try) || _macro_name(ex) == "@testset") &&
    any(arg -> _controlled_function(arg; nested=true), ex.args)
_imports(ex) = ex isa Expr && !(ex.head in (:quote, :inert)) && (ex.head in (:using, :import) || any(_imports, ex.args))

"""
The name of the function a method definition's signature `sig` extends: a symbol for a
function of its own, an expression for a qualified or callable one, `nothing` for an
anonymous function.
"""
function _method_name(sig)
    sig isa Symbol && return sig
    while sig isa Expr && (sig.head === :where || (sig.head === :(::) && length(sig.args) == 2))
        sig = first(sig.args)
    end
    return sig isa Expr && sig.head === :call && !isempty(sig.args) ? first(sig.args) : nothing
end
"The name of the function `ex` defines a method of, as `_method_name` gives it, if `ex` is a method definition."
_definition_name(ex) = ex isa Expr && (ex.head === :function || (ex.head === :(=) && _signature(first(ex.args)))) ?
    _method_name(first(ex.args)) : nothing
_typed_assignee(lhs) = lhs isa Expr && (lhs.head === :(::) || (lhs.head === :tuple && any(_typed_assignee, lhs.args)))

"Names `ex` declares `global` without declaring their types."
function _declared_globals!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    if ex.head === :global
        for arg in ex.args
            arg isa Symbol ? push!(names, arg) :
                arg isa Expr && arg.head === :(=) && union!(names, _assignees(first(arg.args)))
        end
    end
    foreach(arg -> _declared_globals!(names, arg), ex.args)
    return names
end

const _TOPLEVEL_HEADS = (:using, :import, :export, :public, :module, :macro, :struct, :abstract, :primitive)

"""
Whether `ex` holds what only top-level code may: imports and exports, definitions of types,
modules and macros, generated functions, global constants, globals with declared types, and
methods of functions that are not local, such as `Base.show(io::IO, ::T) = …`, `(::T)(x) = …`
or those of a name declared `global`. A local scope at top level defines these globally, a
function body cannot hold them.
"""
function _toplevel_only(ex, globals::Set{Symbol}=_declared_globals!(Set{Symbol}(), ex))
    ex isa Expr && !(ex.head in (:quote, :inert)) || return false
    ex.head in _TOPLEVEL_HEADS && return true
    _macro_name(ex) in ("@enum", "@generated") && return true
    ex.head === :global && any(ex.args) do arg
        arg isa Expr && (arg.head in (:const, :(::), :function) ||
            (arg.head === :(=) && (_signature(first(arg.args)) || _typed_assignee(first(arg.args)))))
    end && return true
    ex.head === :const && any(ex.args) do arg
        arg isa Expr && arg.head === :global ||
            any(in(globals), arg isa Expr && arg.head === :(=) ? _assignees(first(arg.args)) : _assignees(arg))
    end && return true
    ex.head === :(=) && _typed_assignee(first(ex.args)) && any(in(globals), _assignees(first(ex.args))) && return true
    name = _definition_name(ex)
    (name isa Symbol ? name in globals : name !== nothing) && return true
    return any(arg -> _toplevel_only(arg, globals), ex.args)
end

"""
Symbols the signatures of the named functions `ex` defines read, which lowering evaluates
where the function holding them is defined.
"""
function _signature_reads!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    _definition_name(ex) === nothing || _signature_types!(names, first(ex.args))
    foreach(arg -> _signature_reads!(names, arg), ex.args)
    return names
end

"Names `ex` may bind, globally or locally: those it assigns, and the functions and types it defines."
function _may_bind!(names::Set{Symbol}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return names
    name = _definition_name(ex)
    if name !== nothing
        name isa Symbol && push!(names, name)
    elseif ex.head === :(=)
        union!(names, _assignees(first(ex.args)))
    elseif ex.head in (:struct, :abstract, :primitive)
        _symbols!(names, ex.args[ex.head === :struct ? 2 : 1])
    elseif _macro_name(ex) == "@enum"
        foreach(arg -> _symbols!(names, arg), ex.args[3:end])
    elseif ex.head in (:const, :global, :local)
        union!(names, (arg for arg in ex.args if arg isa Symbol))
    end
    foreach(arg -> _may_bind!(names, arg), ex.args)
    return names
end

"""
Whether `ex` defines a function, anonymous or local, in a branch, or with `nested` in a loop
too.
"""
function _controlled_function(ex, controlled::Bool=false; nested::Bool=false)
    ex isa Expr && !(ex.head in (:quote, :inert)) || return false
    (_method(ex) || ex.head === :generator) && return controlled
    ex.head in (:if, :elseif, :&&, :||) &&
        return _controlled_function(first(ex.args), controlled; nested) ||
            any(arg -> _controlled_function(arg, true; nested), ex.args[2:end])
    nested && ex.head in (:for, :while) && return any(arg -> _controlled_function(arg, true; nested), ex.args)
    return any(arg -> _controlled_function(arg, controlled; nested), ex.args)
end

"Whether parameters declare types, which lowering evaluates where a closure stands."
_typed(p) = p isa Expr && (p.head in (:(::), :where) ||
    (p.head in (:tuple, :block, :parameters, :kw, :(=), :...) && any(_typed, p.head in (:kw, :(=)) ? p.args[1:1] : p.args)))

"Whether `ex` defines a closure with typed parameters or a `where` clause."
function _typed_closure(ex)
    ex isa Expr || return false
    ex.head === :-> && _typed(first(ex.args)) && return true
    if ex.head === :function && length(ex.args) == 2
        signature = first(ex.args)
        Meta.isexpr(signature, :(::), 2) && (signature = first(signature.args))
        (Meta.isexpr(signature, :where) || (Meta.isexpr(signature, :tuple) && _typed(signature))) && return true
    end
    return any(_typed_closure, ex.args)
end

"Whether `ex` defines an anonymous function: `x -> ...`, `function (x)::T ... end` or a `do` block's."
function _closure(ex)
    ex isa Expr || return false
    ex.head === :-> && return true
    ex.head === :function && length(ex.args) == 2 || return false
    signature = first(ex.args)
    while signature isa Expr && signature.head in (:(::), :where) && !isempty(signature.args)
        signature = first(signature.args)
    end
    return signature isa Expr && signature.head === :tuple
end

"Symbols `ex` evaluates: those outside quoted code, and those interpolated into it."
function _evaluated_symbols!(names::Set{Symbol}, ex, quoted::Bool=false)
    if ex isa Symbol
        quoted || push!(names, ex)
    elseif ex isa Expr
        quoted = ex.head === :quote ? true : ex.head === :$ ? false : quoted
        foreach(arg -> _evaluated_symbols!(names, arg, quoted), (quoted ? ex : something(_command(ex), ex)).args)
    end
    return names
end

"""
Symbols a method signature evaluates when the method is defined: argument types, `where`
bounds and the return type, not argument names or default values.
"""
function _signature_types!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    if ex.head === :where
        _signature_types!(names, first(ex.args))
        for bound in ex.args[2:end]
            bound isa Expr && bound.head in (:<:, :>:) ? _symbols!(names, last(bound.args)) :
                bound isa Expr && bound.head === :comparison ? foreach(b -> _symbols!(names, b), bound.args[[1, end]]) : nothing
        end
    elseif ex.head === :(::)
        _symbols!(names, last(ex.args))
        length(ex.args) == 2 && _signature_types!(names, first(ex.args))
    elseif ex.head in (:call, :tuple, :parameters)
        for argument in ex.args
            argument isa Expr && argument.head === :kw && (argument = first(argument.args))
            argument isa Expr && argument.head === :... && (argument = first(argument.args))
            argument isa Expr && argument.head in (:(::), :parameters, :curly) && _signature_types!(names, argument)
        end
    elseif ex.head === :curly
        foreach(argument -> _symbols!(names, argument), ex.args)
    end
    return names
end

"""
Symbols code that `eval` runs at top level reads: those outside method and closure bodies,
argument names and quoted symbols, and those interpolated anywhere, which are read when the
code is built.
"""
function _code_reads!(names::Set{Symbol}, ex)
    if ex isa Symbol
        push!(names, ex)
    elseif ex isa Expr && ex.head === :$
        _symbols!(names, ex)
    elseif ex isa Expr && !(ex.head === :inert)
        if ex.head === :-> || _method(ex) || ex.head === :struct
            _interpolated!(names, ex)
            ex.head === :-> || (_method(ex) ? _signature_types!(names, first(ex.args)) : _type_symbols!(names, ex))
        else
            foreach(arg -> _code_reads!(names, arg), something(_command(ex), ex).args)
        end
    end
    return names
end

_interpolated!(names::Set{Symbol}, ex) =
    ex isa Expr ? (ex.head === :$ ? _symbols!(names, ex) : foreach(arg -> _interpolated!(names, arg), ex.args); names) : names

"Symbols a type definition evaluates: its header, field types and constructor signatures."
function _type_symbols!(names::Set{Symbol}, ex::Expr)
    ex.head === :struct || return _symbols!(names, ex)
    _symbols!(names, ex.args[2])
    for field in ex.args[3].args
        field isa Expr && field.head === :(=) && !_signature(first(field.args)) && (field = first(field.args))
        field isa Expr && field.head === :(::) ? _symbols!(names, last(field.args)) :
            _method(field) && !_closure(field) ? _signature_types!(names, first(field.args)) : nothing
    end
    return names
end

"Macros that run their code where they stand, so that a `return` or `@goto` in it leaves the code around them."
const _INLINE_MACROS = Set(["@testset", "@sync", "@static", "@time", "@timev", "@timed", "@elapsed", "@allocated",
                            "@allocations", "@inbounds", "@views", "@lock"])

"""
Push the conditions under which statement `ex` exits early with one of `exits` onto
`conditions`, as `file in SKIPPED` of `file in SKIPPED && continue`: those of the branches
and loops around each exit that leaves `ex`. A `@goto` counts as a `return`, since it may
jump out of any block or loop around it. A `break` or `continue` in a loop of `ex` leaves
only that loop, and code in functions exits nothing, nor does a `return` or `@goto` in
macros other than `_INLINE_MACROS`, which may wrap their code in a function, as `@async` does.
"""
function _exits!(conditions::Vector{Any}, ex, exits::Tuple, path::Vector{Any}=Any[])
    ex isa Expr && !(ex.head in (:quote, :inert, :module)) && !_method(ex) || return conditions
    head = ex.head
    if head in exits || (:return in exits && _macro_name(ex) == "@goto")
        append!(conditions, path)
    elseif head in (:if, :elseif, :&&, :||)
        _exits!(conditions, first(ex.args), exits, path)
        foreach(arg -> _exits!(conditions, arg, exits, [path; first(ex.args)]), ex.args[2:end])
    elseif head in (:for, :while)
        :return in exits && _exits!(conditions, last(ex.args), (:return,), [path; first(ex.args)])
    elseif head === :macrocall
        inner = _macro_name(ex) in _INLINE_MACROS ? exits : filter(!=(:return), exits)
        foreach(arg -> _exits!(conditions, arg, inner, path), ex.args[2:end])
    else
        foreach(arg -> _exits!(conditions, arg, exits, path), ex.args)
    end
    return conditions
end

"What `_reads!` gathers from a statement, and what it knows of the conditional the statement may be."
struct _Reads
    "The names whose values JETLS evaluates."
    direct::Set{Symbol}
    "The names assignments bind, with the names their values and conditions read."
    locals::Vector{Pair{Set{Symbol},Set{Symbol}}}
    "The names the statement binds, if it is a conditional the worker does not outline."
    bound::Set{Symbol}
    "Whether that conditional may bind any name, as when it imports or includes."
    opaque::Bool
end

"Whether `part`, a statement of a conditional, is moved out of it (see `_reads!`)."
function _moved(reads::_Reads, part)
    _outlined(part) || return false
    names = _signature_reads!(Set{Symbol}(), part)
    return isempty(names) || (!reads.opaque && isdisjoint(names, reads.bound))
end

_needs!(reads::_Reads, parts, controls) =
    (foreach(part -> _evaluated_symbols!(reads.direct, part), parts); foreach(c -> _symbols!(reads.direct, c), controls))

# What follows an early exit, as `include(file)` follows `file in SKIPPED && continue`,
# runs only where its conditions let it.
_exited(controls, part) = (exits = _exits!(Any[], part, (:break, :continue, :return));
                           isempty(exits) ? controls : [controls; exits])

# Functions defined in loops, `let` and `try` blocks are local: closures. The closures in
# statements moved out of a conditional need no conditions either.
function _visit_reads!(reads::_Reads, ex, controls::Vector{Any}, branches::Vector{Any}, scoped::Bool, forced::Bool,
                       toplevel::Bool=false)
    ex isa Expr || return
    head = ex.head
    if toplevel && head in (:if, :elseif, :block)
        parts = head === :block ? ex.args : ex.args[2:end]
        if head !== :block
            condition = first(ex.args)
            _visit_reads!(reads, condition, controls, branches, scoped, forced)
            controls, branches = [controls; condition], [branches; condition]
        end
        for part in parts
            outlined = forced || head === :block && _moved(reads, part)
            _visit_reads!(reads, part, controls, branches, scoped, outlined,
                          !outlined && Meta.isexpr(part, head === :block ? (:if, :block) : (:elseif, :block)))
            head === :block && (controls = _exited(controls, part))
        end
    elseif head in (:quote, :inert, :module)
        return
    elseif head === :macrocall
        name = _macro_name(ex)
        name in _TEST_MACROS && return     # JETLS outlines their closures into thunks
        # `@eval [module] code` evaluates its module, and the code at top level.
        name == "@eval" &&
            return (foreach(arg -> _code_reads!(reads.direct, arg), ex.args[2:end]); _needs!(reads, Any[], controls))
        # `@static` evaluates its condition when it expands.
        !forced && name == "@static" && last(ex.args) isa Expr && last(ex.args).head === :if &&
            _needs!(reads, Any[first(last(ex.args).args)], controls)
        # JETLS evaluates the deprecation `@deprecate_binding` declares, and the constant
        # holding its message.
        !forced && name == "@deprecate_binding" && _needs!(reads, Any[get(ex.args, 6, nothing)], controls)
        for arg in ex.args[2:end]
            _visit_reads!(reads, arg, controls, branches, scoped, forced)
        end
    elseif _is_include(ex) || (head === :call && _name(first(ex.args)) == "include_string")
        _needs!(reads, ex.args[2:end], controls)
    elseif head === :call && _name(first(ex.args)) == "eval"
        foreach(arg -> _code_reads!(reads.direct, arg), ex.args[2:end])
        _needs!(reads, Any[], controls)
    elseif head === :call && _name(first(ex.args)) == "deprecate" &&
           _macro_name(get(ex.args, 2, nothing)) == "@__MODULE__"
        # JETLS evaluates only the deprecations of the module's own bindings.
        forced || _needs!(reads, Any[], controls)
    elseif _method(ex)
        forced || (_closure(ex) || scoped ? _needs!(reads, branches, Any[]) :
                   (_signature_types!(reads.direct, first(ex.args)); _needs!(reads, Any[], controls)))
    elseif head in (:struct, :abstract, :primitive)
        forced || (_type_symbols!(reads.direct, ex); _needs!(reads, Any[], controls))
    elseif head in (:using, :import)
        forced || _needs!(reads, Any[], controls)
    elseif head in (:if, :elseif, :&&, :||)
        condition = first(ex.args)
        _visit_reads!(reads, condition, controls, branches, scoped, forced)
        for arg in ex.args[2:end]
            _visit_reads!(reads, arg, [controls; condition], [branches; condition], scoped, forced)
        end
    elseif head in (:for, :while)
        _visit_reads!(reads, first(ex.args), controls, branches, scoped, forced)
        # A `break`, `return` or `@goto` decides whether the later iterations run.
        body = _exits!([controls; first(ex.args)], last(ex.args), (:break, :return))
        _visit_reads!(reads, last(ex.args), body, branches, true, forced)
    elseif head === :let
        _visit_reads!(reads, first(ex.args), controls, branches, scoped, forced)
        _visit_reads!(reads, last(ex.args), controls, branches, true, forced)
    elseif head === :try
        for arg in ex.args
            _visit_reads!(reads, arg, controls, branches, true, forced)
        end
    elseif head === :block
        for part in ex.args
            _visit_reads!(reads, part, controls, branches, scoped, forced)
            controls = _exited(controls, part)
        end
    else
        !forced && head in (:generator, :comprehension, :typed_comprehension, :do) && _needs!(reads, branches, Any[])
        if head === :(=) && !_signature(first(ex.args))
            push!(reads.locals, _symbols(first(ex.args)) => union(_symbols(last(ex.args)), map(_symbols, controls)...))
        end
        for arg in ex.args
            _visit_reads!(reads, arg, controls, branches, scoped, forced)
        end
    end
end

"""
Add the names whose values JETLS evaluates when it analyzes the top-level statement `ex`:
arguments of `include` and `eval` calls, signatures of definitions, messages of
`@deprecate_binding`, the control flow around these and around imports and deprecations, and
the conditions of branches that define closures, which JETLS evaluates to define them; with
`forced`, only those of `include` and `eval` calls, which JETLS evaluates whatever they need.
Assignments in `ex` that these names depend on count too. Control flow includes early exits:
the conditions of a `continue`, `break`, `return` or `@goto` control what follows it, and
those of a `break`, `return` or `@goto` every iteration of its loop.
"""
function _reads!(needed::Set{Symbol}, ex; forced::Bool=false)
    # Closures in an outlined expression's branches need no conditions.
    whole = forced || _outlined(ex)
    # A conditional the worker does not outline has the statements of its branches that it
    # would outline standing alone moved out of it, before it, unless their typed local
    # functions may need what it defines: names it binds, or any when it imports or includes.
    conditional = !whole && ex isa Expr && ex.head === :if
    bound = conditional ? _may_bind!(Set{Symbol}(), ex) : Set{Symbol}()
    opaque = conditional && (_stays(ex) || _imports(ex))
    direct = Set{Symbol}()
    locals = Pair{Set{Symbol},Set{Symbol}}[]
    _visit_reads!(_Reads(direct, locals, bound, opaque), ex, Any[], Any[], false, whole, conditional)
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
only where needed, or where JETLS evaluates part of them anyway; impure assignments only
where `include` and `eval` calls need them. A need selects the binding of a name that
reaches the statement needing it. `excluded` statements are not evaluated.
"""
function _concretized(expressions::Vector{Any}, excluded::Set{Int}, modules::Set{Symbol}=Set{Symbol}())
    shadowed = Set{Symbol}()
    foreach(ex -> (_binds!(shadowed, ex); _globals!(shadowed, ex)), expressions)
    scope = _Scope(setdiff(modules, shadowed), Set{Symbol}(), shadowed)
    variable = setdiff(union(_PROCESS_NAMES, _RUN_DEPENDENT), shadowed)
    bound = Set{Symbol}()
    selected = Set{Int}()
    # Statements to evaluate where needed, with what they read and whether they are pure.
    deferred = Dict{Int,Tuple{Set{Symbol},Bool}}()
    # Needs: a name, the statement needing it, and whether JETLS evaluates it whatever it is.
    needs = Tuple{Symbol,Int,Bool}[]
    need!(names, i, forced) = foreach(name -> push!(needs, (name, i, forced)), names)
    bindings = Dict{Symbol,Vector{Int}}()
    for (i, ex) in pairs(expressions)
        binds = _binds!(Set{Symbol}(), ex)
        assignment = _assignment(ex)
        reads = _evaluated_symbols!(Set{Symbol}(), assignment === nothing ? ex : last(assignment))
        known = i in excluded ? nothing : _evaluable(ex, scope, bound)
        setdiff!(scope.known, binds)
        if known === nothing
            !(i in excluded) && assignment !== nothing && (deferred[i] = (reads, false))
            need!(_reads!(Set{Symbol}(), ex; forced=true), i, true)
            need!(_reads!(Set{Symbol}(), ex), i, false)
            setdiff!(variable, binds)
        elseif isdisjoint(reads, variable)
            push!(selected, i)
            union!(scope.known, known)
            setdiff!(variable, binds)
        else
            # JETLS evaluates the conditions of a statement anyway when it defines closures in
            # its branches, and then not the closures of branches not taken: evaluating it whole
            # is better, unless what it evaluates besides the conditions depends on the run.
            evaluated = _reads!(Set{Symbol}(), ex)
            if !isempty(evaluated) && isdisjoint(setdiff(reads, evaluated), variable)
                push!(selected, i)
                need!(reads, i, false)
            else
                deferred[i] = (reads, true)
            end
            need!(evaluated, i, false)
            union!(scope.known, known)
            union!(variable, binds)
        end
        # JETLS evaluates type aliases such as `const V = Vector{T}` itself.
        assignment !== nothing && Meta.isexpr(last(assignment), :curly) && need!(reads, i, true)
        _define!(scope, ex)
        setdiff!(scope.known, _mutated!(Set{Symbol}(), ex))
        union!(bound, binds)
        foreach(name -> push!(get!(bindings, name, Int[]), i), binds)
    end
    while !isempty(needs)
        name, i, forced = pop!(needs)
        positions = get(bindings, name, Int[])
        k = findlast(<(i), positions)
        k === nothing && continue
        k = positions[k]
        # A conditional or block may leave the name as an earlier statement bound it.
        _assignment(expressions[k]) === nothing && push!(needs, (name, k, forced))
        haskey(deferred, k) && !(k in selected) || continue
        reads, pure = deferred[k]
        pure || forced || continue
        push!(selected, k)
        need!(reads, k, forced)
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
    concretization_patterns(file; modules=Set{Symbol}()) -> Vector{String}

The source text of the top-level statements of `file` that analysis may evaluate, each a
JETLS concretization pattern. `modules` names the modules code that runs before the file
imports, such as a test driver's prelude.
"""
function concretization_patterns(file::String; modules::Set{Symbol}=Set{Symbol}())
    text, statements = _statements(file; modules=true, blocks=false)
    expressions = Any[last(statement) for statement in statements]
    excluded = Set{Int}()
    while true
        selected = _concretized(expressions, excluded, modules)
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
# those global assignments, modules and conditional definitions, as in `@static if`, that
# the test file or those definitions refer to, transitively. Selection logic such as
# `const TESTS = isempty(ARGS) ? ALL : ARGS` is left out, since nothing the test file uses
# depends on it. Statements keep their original source text, with `@__DIR__`, `@__FILE__`
# and relative include paths pinned to their original file. Pure assignments and
# conditionals are wrapped in `@eval`, which analysis always evaluates, since concretization
# patterns cannot apply to the generated file.

function _macro_identifier(node::JS.SyntaxNode)
    JS.kind(node) == JS.K"macrocall" || return nothing
    name = first(_children(node))
    JS.kind(name) == JS.K"." && (name = last(_children(name)))
    JS.kind(name) == JS.K"macro_name" || return nothing
    return _value(first(_children(name)))
end

function _include_literal(node::JS.SyntaxNode)
    JS.kind(node) == JS.K"call" || return nothing
    children = _children(node)
    length(children) >= 2 || return nothing
    callee = first(children)
    JS.kind(callee) == JS.K"." && (callee = last(_children(callee)))
    _value(callee) === :include || return nothing
    path = last(children)
    JS.kind(path) == JS.K"string" && length(_children(path)) == 1 || return nothing
    literal = only(_children(path))
    value = _value(literal)
    JS.kind(literal) == JS.K"String" && value isa String || return nothing
    return path => value
end

"Push the edits that pin the locations `node` depends on to `file` onto `edits`."
function _relocations!(edits::Vector{Pair{UnitRange{Int},String}}, node::JS.SyntaxNode, file::String)
    macro_name = _macro_identifier(node)
    if macro_name in (:__DIR__, :__FILE__)
        return push!(edits, JS.byte_range(node) => repr(macro_name === :__DIR__ ? dirname(file) : file))
    end
    literal = _include_literal(node)
    if literal !== nothing && !isabspath(last(literal))
        push!(edits, JS.byte_range(first(literal)) => repr(normpath(dirname(file), last(literal))))
    end
    JS.is_leaf(node) || foreach(child -> _relocations!(edits, child, file), _children(node))
    return edits
end

"The source text of `node`, with locations that depend on its file pinned to `file`."
function _relocated(node::JS.SyntaxNode, text::String, file::String)
    edits = _relocations!(Pair{UnitRange{Int},String}[], node, file)
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

"A statement of a test driver that a prelude may copy, with where it is from and its source text."
struct _DriverStatement
    file::String
    line::Int
    ex::Expr
    "The names that select it, those an assignment, module or conditional binds; empty for imports and definitions."
    names::Vector{Symbol}
    text::String
end

"Include calls in `ex` that run when it does, outside function bodies and modules."
function _nested_includes!(includes::Vector{Expr}, ex)
    ex isa Expr && !(ex.head in (:quote, :inert, :module)) && !_method(ex) || return includes
    _is_include(ex) ? push!(includes, ex) : foreach(arg -> _nested_includes!(includes, arg), ex.args)
    return includes
end

"""
Collect the statements of `file` that set up what it includes as `next`: those before the
include of `next`, or before its first run-time include, also from the files it includes
statically before then. Returns whether that include was reached.
"""
function _driver_statements!(statements::Vector{_DriverStatement}, file::String, next::String, seen::Set{String},
                             packages::Dict{String,Project})
    file in seen && return false
    push!(seen, file)
    text, nodes = _statements(file)
    return _driver_nodes!(statements, file, text, nodes, next, seen, packages, Dict{Symbol,String}())
end

function _driver_nodes!(statements::Vector{_DriverStatement}, file::String, text::String, nodes, next::String,
                        seen::Set{String}, packages::Dict{String,Project}, bindings::Dict{Symbol,String})
    # The include of `next`, or a run-time include, which may be of `next`, ends the setup.
    function stops(ex)
        for include in _nested_includes!(Expr[], ex)
            path = _path(last(include.args), file, bindings, packages)
            (path === nothing || normpath(dirname(file), path) == next) && return true
        end
        return false
    end
    for (node, ex) in nodes
        # A branch of a top-level conditional runs at top level too, so what it does before
        # it reaches the include sets the included file up.
        branch = _reaching_branch(node, ex, stops)
        branch === nothing ||
            return _driver_nodes!(statements, file, text, branch, next, seen, packages, bindings)
        # Top-level includes set up context, as helpers do. Included files run at top level
        # wherever the call is, but other includes are test files, except nested drivers
        # included inside a `@testset`, say.
        for include in _nested_includes!(Expr[], ex)
            path = _path(last(include.args), file, bindings, packages)
            path === nothing && return true
            path = normpath(dirname(file), path)
            path == next && return true
            (_is_include(ex) || basename(path) == "runtests.jl") && isfile(path) &&
                _driver_statements!(statements, path, next, seen, packages) && return true
        end
        _is_include(ex) && continue
        assignment = _assignment(ex)
        if assignment !== nothing
            names, value = assignment
            known = length(names) == 1 ? _path(value, file, bindings, packages) : nothing
            known === nothing ? foreach(name -> delete!(bindings, name), names) : (bindings[only(names)] = known)
        end
        conditional = _conditional_definitions(ex)
        if ex isa Expr && (ex.head in (:using, :import) || _definition(ex) || assignment !== nothing || conditional)
            # A module or conditional, like an assignment, is kept only where something refers to what it
            # binds, if anything.
            # A conditional `using` of a whole module binds names that are not known statically, so it
            # is kept as an import is.
            names = assignment !== nothing ? first(assignment) : ex.head === :module ? _bound_names(ex) :
                conditional && !_whole_using(ex) ? collect(_binds!(Set{Symbol}(), ex)) : Symbol[]
            push!(statements, _DriverStatement(file, JS.source_line(node), ex, names, _relocated(node, text, file)))
        end
    end
    return false
end

"""
The statements of the branch of the top-level conditional `ex`, parsed as `node`, that holds an
include `stops` accepts, if any.
"""
function _reaching_branch(node::JS.SyntaxNode, ex, stops)
    Meta.isexpr(ex, (:if, :elseif)) || return nothing
    children = _children(node)
    for i in 2:min(length(ex.args), length(children))
        stops(ex.args[i]) || continue
        Meta.isexpr(ex.args[i], :elseif) && return _reaching_branch(children[i], ex.args[i], stops)
        return _flatten!(Tuple{JS.SyntaxNode,Any}[], children[i])
    end
    return nothing
end

"Whether `ex` runs a `using` of a whole module, as in `using Dates`, whose names are not known statically."
_whole_using(ex) = ex isa Expr && (ex.head === :using ? any(path -> !(path isa Expr && path.head === :(:)), ex.args) :
    ex.head in (:block, :if, :elseif, :macrocall) && any(_whole_using, ex.args))

"The modules the relative imports in `ex`, such as `using .Helpers` or `import ..Tools: f`, name."
function _relative_modules(ex)
    ex isa Expr || return Symbol[]
    ex.head in (:block, :if, :elseif, :macrocall) && return reduce(vcat, (_relative_modules(arg) for arg in ex.args); init=Symbol[])
    ex.head in (:using, :import) || return Symbol[]
    paths = [path isa Expr && path.head in (:(:), :as) ? first(path.args) : path for path in ex.args]
    return Symbol[path.args[2] for path in paths
                  if path isa Expr && path.head === :. && length(path.args) >= 2 && first(path.args) === :. &&
                     path.args[2] isa Symbol]
end

function _drivers_statements(drivers::Vector{String}, target::String, packages::Dict{String,Project})
    statements = _DriverStatement[]
    seen = Set{String}()
    for (i, driver) in pairs(drivers)
        _driver_statements!(statements, driver, i < length(drivers) ? drivers[i+1] : target, seen, packages)
    end
    return statements
end

"The modules the prelude of `drivers` for `target` imports, which `target` can read."
prelude_modules(drivers::Vector{String}, target::String; packages::Dict{String,Project}=Dict{String,Project}()) =
    union(Set{Symbol}(), (_modules(statement.ex) for statement in _drivers_statements(drivers, target, packages))...)

"""
    prelude(drivers, target; packages) -> String

Source text recreating the context that `drivers`, outermost first, establish for `target`,
which the last of them includes at run time: imports, definitions and the global
assignments, modules and conditional definitions `target` transitively refers to, also from
files the drivers include statically. `packages` are those whose `pkgdir` and `pathof` the
files may name in include paths, by name.
"""
function prelude(drivers::Vector{String}, target::String; packages::Dict{String,Project}=Dict{String,Project}())
    statements = _drivers_statements(drivers, target, packages)
    needed = Set{Symbol}()
    pending, visited = [target], Set{String}()
    while !isempty(pending)
        file = pop!(pending)
        (file in visited || !isfile(file)) && continue
        push!(visited, file)
        _symbols!(needed, Meta.parseall(read(file, String); filename=file))
        append!(pending, (i.target for i in parse_source(file, packages).includes if !isempty(i.target)))
    end
    # A relative import of a module the prelude does not define would fail.
    defined = Set{Symbol}(name for statement in statements if statement.ex.head === :module for name in statement.names)
    selected = [isempty(statement.names) && issubset(_relative_modules(statement.ex), defined) for statement in statements]
    for (statement, keep) in zip(statements, selected)
        keep && _symbols!(needed, statement.ex)
    end
    changed = true
    while changed
        changed = false
        for (i, statement) in pairs(statements)
            selected[i] && continue
            any(in(needed), statement.names) && issubset(_relative_modules(statement.ex), defined) || continue
            selected[i] = changed = true
            _symbols!(needed, statement.ex)
        end
    end
    statements = statements[selected]
    evaluated = _concretized(Any[statement.ex for statement in statements], Set{Int}())
    io = IOBuffer()
    for (i, statement) in pairs(statements)
        println(io, "#= ", statement.file, ":", statement.line, " =#")
        println(io, i in evaluated ? "@eval begin\n$(statement.text)\nend" : statement.text)
    end
    return String(take!(io))
end
