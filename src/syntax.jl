# Static source facts. Parsing never executes user code; anything that depends on run-time
# values stays unresolved and is reported as such.

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
_is_include(ex) = ex isa Expr && ex.head === :call && _name(first(ex.args)) == "include" &&
    2 <= length(ex.args) <= 3

"Evaluate a path expression built from literals, `@__DIR__`, `@__FILE__` and path calls."
function _path(ex, file::String, bindings::Dict{Symbol,String}, packages::Dict{String,String})
    ex isa String && return ex
    ex isa Symbol && return get(bindings, ex, nothing)
    ex isa Expr || return nothing
    if ex.head === :macrocall
        _macro_name(ex) == "@__DIR__" && return dirname(file)
        _macro_name(ex) == "@__FILE__" && return file
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

function _assigned!(names::Set{Symbol}, ex)
    ex isa Expr || return names
    ex.head === :(=) && first(ex.args) isa Symbol && push!(names, first(ex.args))
    foreach(arg -> _assigned!(names, arg), ex.args)
    return names
end

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
        return Syntax(includes, ["$file: cannot be parsed: $(sprint(showerror, err))"])
    end
    line = 1
    function visit(ex, bindings::Dict{Symbol,String}, followed::Bool)
        ex isa LineNumberNode && (line = ex.line; return)
        ex isa Expr || return
        if ex.head in (:error, :incomplete)
            push!(notes, "$file:$line: cannot be parsed: $(join(string.(ex.args), ' '))")
            return
        elseif ex.head === :quote
            return
        elseif _is_include(ex)
            target = _path(last(ex.args), file, bindings, packages)
            if target === nothing
                push!(notes, "$file:$line: include target is only known at run time")
                push!(includes, Include("", line, followed))
            else
                push!(includes, Include(normpath(dirname(file), target), line, followed))
            end
        elseif ex.head === :(=) && first(ex.args) isa Symbol
            value = _path(last(ex.args), file, bindings, packages)
            value === nothing ? delete!(bindings, first(ex.args)) : (bindings[first(ex.args)] = value)
        end
        # Bindings made inside conditionals, scopes and modules do not leak outward.
        scoped = _method(ex) || ex.head in (:module, :let, :for, :while, :if, :elseif, :try, :&&, :||)
        inner = scoped ? copy(bindings) : bindings
        for arg in ex.args
            visit(arg, inner, followed && !_method(ex))
        end
        scoped && ex.head !== :module && foreach(name -> delete!(bindings, name), _assigned!(Set{Symbol}(), ex))
        return
    end
    visit(tree, Dict{Symbol,String}(), true)
    return Syntax(unique!(includes), unique!(notes))
end

# Test-driver preludes
# ====================
#
# A test file that its driver (`test/runtests.jl`) includes from a run-time loop is
# analyzed as its own unit after a prelude: the driver's imports and definitions, and only
# those global assignments that the test file or those definitions refer to, transitively.
# Selection logic such as `const TESTS = isempty(ARGS) ? ALL : ARGS` is left out, since
# nothing the test file uses depends on it.

_symbols!(names::Set{Symbol}, ex::Symbol) = push!(names, ex)
_symbols!(names::Set{Symbol}, ex::Expr) = (foreach(arg -> _symbols!(names, arg), ex.args); names)
_symbols!(names::Set{Symbol}, ex::QuoteNode) = _symbols!(names, ex.value)
_symbols!(names::Set{Symbol}, ::Any) = names

_assignee(lhs::Symbol) = lhs
_assignee(lhs::Expr) = lhs.head === :(::) && first(lhs.args) isa Symbol ? first(lhs.args) : nothing
_assignee(::Any) = nothing

"The global a top-level assignment binds, or `nothing` for any other statement."
function _assignment(ex)
    ex isa Expr || return nothing
    ex.head in (:const, :global) && length(ex.args) == 1 && return _assignment(only(ex.args))
    ex.head === :(=) && !_signature(first(ex.args)) && return _assignee(first(ex.args))
    return nothing
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

"Replace `@__DIR__` and `@__FILE__` with the location of the statement's original file."
function _relocate(ex, file::String)
    ex isa Expr || return ex
    _macro_name(ex) == "@__DIR__" && return dirname(file)
    _macro_name(ex) == "@__FILE__" && return file
    return Expr(ex.head, (_relocate(arg, file) for arg in ex.args)...)
end

_toplevel(ex) = ex isa Expr && ex.head in (:toplevel, :block) ? mapreduce(_toplevel, vcat, ex.args; init=Any[]) : Any[ex]

function _driver_statements!(statements, file::String, target::String, seen::Set{String})
    file in seen && return statements
    push!(seen, file)
    line = 1
    bindings = Dict{Symbol,String}()
    for ex in _toplevel(Meta.parseall(read(file, String); filename=file))
        ex isa LineNumberNode && (line = ex.line; continue)
        if _is_include(ex)
            path = _path(last(ex.args), file, bindings, Dict{String,String}())
            path === nothing && continue
            path = normpath(dirname(file), path)
            path != target && isfile(path) && _driver_statements!(statements, path, target, seen)
        elseif ex isa Expr && (ex.head in (:using, :import) || _definition(ex) || _assignment(ex) !== nothing)
            if ex.head === :(=) && first(ex.args) isa Symbol
                value = _path(last(ex.args), file, bindings, Dict{String,String}())
                value === nothing || (bindings[first(ex.args)] = value)
            end
            push!(statements, (; file, line, ex))
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
    selected = [_assignment(statement.ex) === nothing for statement in statements]
    for (statement, keep) in zip(statements, selected)
        keep && _symbols!(needed, statement.ex)
    end
    changed = true
    while changed
        changed = false
        for (i, statement) in pairs(statements)
            selected[i] && continue
            _assignment(statement.ex) in needed || continue
            selected[i] = changed = true
            _symbols!(needed, statement.ex)
        end
    end
    io = IOBuffer()
    for (statement, keep) in zip(statements, selected)
        keep || continue
        println(io, "#= ", statement.file, ":", statement.line, " =#")
        Base.show_unquoted(io, _relocate(statement.ex, statement.file))
        println(io)
    end
    return String(take!(io))
end
