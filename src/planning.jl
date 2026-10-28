_unit_id(kind::Symbol, entry::String, root::String, extension::String="") =
    string(kind, '-', bytes2hex(sha256(string(_slash(relpath(entry, root)), '\0', extension)))[1:12])

"Files reachable from `entry` through statically resolved includes, optionally only those analysis follows."
function _reach(entry::String, syntax::Dict{String,Syntax}; followed_only::Bool, within=nothing)
    seen = Set{String}()
    pending = [entry]
    while !isempty(pending)
        file = pop!(pending)
        (file in seen || (within !== nothing && !(file in within))) && continue
        push!(seen, file)
        facts = get(syntax, file, nothing)
        facts === nothing && continue
        for include in facts.includes
            isempty(include.target) || (followed_only && !include.followed) || push!(pending, include.target)
        end
    end
    return seen
end

"""
Choose entry files that cover `files`, each covering what it includes. An entry is a file
that every file including it, directly or not, is itself included by: a file nothing else
in the set includes, or the first file of an include cycle nothing outside it includes.
"""
function _entries(files::Vector{String}, syntax::Dict{String,Syntax})
    remaining = Set(files)
    reach = Dict(file => _reach(file, syntax; followed_only=true, within=remaining) for file in files)
    entries = Pair{String,Vector{String}}[]
    for file in sort(files)
        file in remaining || continue
        all(other -> !(file in reach[other]) || other in reach[file], files) || continue
        covered = sort!(collect(intersect(reach[file], remaining)))
        setdiff!(remaining, covered)
        push!(entries, file => covered)
    end
    return entries
end

"""
The test driver that runs `file`: the nearest `runtests.jl` above it within its package's
test directory, or the driver unit covering that file when another driver includes it. A
driver above the swept directory runs it too.
"""
function _driver(file::String, owner::String, covering::Dict{String,String})
    tests = joinpath(owner, "test")
    directory = dirname(file)
    while _within(directory, tests)
        candidate = joinpath(directory, "runtests.jl")
        candidate != file && (haskey(covering, candidate) || isfile(candidate)) &&
            return get(covering, candidate, candidate)
        directory == tests && break
        directory = dirname(directory)
    end
    return ""
end

function _extension_entry(package::Project, name::String)
    for path in (joinpath(package.dir, "ext", "$name.jl"), joinpath(package.dir, "ext", name, "$name.jl"))
        isfile(path) && return path
    end
    return ""
end

"The context of a package's tests: its test project when it has one, and its test dependencies."
function _test_context(owner::String)
    tests = joinpath(owner, "test")
    project = any(name -> isfile(joinpath(tests, name)), _PROJECT_FILES) ? tests : owner
    return Context(project, owner, true, Dict{String,String}())
end

"The path constants `file` defines, after those of the files it includes at top level, recorded in `exports`."
function _exported!(exports::Dict{String,Dict{Symbol,String}}, syntax::Dict{String,Syntax}, file::String,
                    seen::Set{String})
    haskey(exports, file) && return exports[file]
    (file in seen || !haskey(syntax, file)) && return Dict{Symbol,String}()
    push!(seen, file)
    bindings = Dict{Symbol,String}()
    for include in syntax[file].includes
        include.depth == 0 && include.followed && !isempty(include.target) &&
            merge!(bindings, _exported!(exports, syntax, include.target, seen))
    end
    return exports[file] = merge!(bindings, syntax[file].bindings)
end

"""
The include facts of every inventoried source, and of the files they include from outside the
sweep. An include that names a path through a constant another file defines, as
`include(joinpath(LIBDIR, "x.jl"))` after including the file that defines `LIBDIR`, resolves
on a second pass.
"""
function source_syntax(inventory::Inventory)
    projects = Dict(project.dir => project for project in inventory.projects)
    syntax = Dict{String,Syntax}(source.path => parse_source(source.path, _packages(source, projects))
                                 for source in inventory.sources)
    # The path constants a file defines, after those of the files it includes at top level.
    exports = Dict{String,Dict{Symbol,String}}()
    foreach(file -> _exported!(exports, syntax, file, Set{String}()), collect(keys(syntax)))
    for source in inventory.sources
        any(include -> isempty(include.target), syntax[source.path].includes) &&
            (syntax[source.path] = parse_source(source.path, _packages(source, projects); exports))
    end
    # Files the sources include from outside the sweep, as the tests of a sweep of a package's test
    # directory may include its scripts: what they include and import counts as in a sweep of all.
    pending = [(include.target, source) for source in inventory.sources for include in syntax[source.path].includes]
    while !isempty(pending)
        file, source = pop!(pending)
        (isempty(file) || haskey(syntax, file) || !isfile(file)) && continue
        syntax[file] = parse_source(file, _packages(source, projects); exports)
        append!(pending, ((include.target, source) for include in syntax[file].includes))
    end
    return syntax
end

"""
    plan(inventory, config=Config(); syntax=source_syntax(inventory)) -> Vector{Unit}

Partition the inventory into analysis units:

- each package entry and each declared extension, covering the files they include, and
  for a package also its other `src/` files: those loading leaves out become orphan units
  during the sweep;
- each package's `test/runtests.jl`, covering the files analysis follows from it, and
  every other test file as its own unit after a prelude of the definitions of the drivers
  that run it;
- scripts, grouped by the files they include, in their nearest environment; a package's
  own scripts use its test environment;
- extension sources no extension includes, with the package's bindings in scope.

Includes are found by parsing, without executing any code. `config`'s `[[context]]` tables
apply to the units they select; [`sweep`](@ref) checks that each selects one.
"""
function plan(inventory::Inventory, config::Config=Config(); syntax::Dict{String,Syntax}=source_syntax(inventory))::Vector{Unit}
    root = inventory.root
    sources = Dict(source.path => source for source in inventory.sources)
    projects = Dict(project.dir => project for project in inventory.projects)
    notes(files) = sort!(unique!(reduce(vcat, (syntax[file].notes for file in files if haskey(syntax, file)); init=String[])))
    units = Unit[]
    covered = Set{String}()
    function add!(kind, entry, context, expected; driver="", extension="")
        expected = sort!(unique!([filter(file -> haskey(sources, file), collect(expected)); entry]))
        union!(covered, expected)
        push!(units, Unit(_unit_id(kind, entry, root, extension), kind, entry, context, expected,
                          driver, extension, Overrides(), notes(expected)))
    end
    owned(owner) = file -> haskey(sources, file) && sources[file].owner == owner

    # A package loads in the environment of the project it leaves a dependency's source to, if any.
    hosts = Dict(project.dir => _host(project, projects) for project in inventory.projects if ispackage(project))
    for package in sort!(filter(ispackage, inventory.projects); by=project -> project.dir)
        files = union(filter(owned(package.dir), _reach(package.entry, syntax; followed_only=false)),
                      (s.path for s in inventory.sources if s.owner == package.dir && s.kind === :package))
        # A sweep of part of a package's sources, whose entry is above the root, analyzes the package.
        (haskey(sources, package.entry) || !isempty(files)) &&
            add!(:package, package.entry, Context(hosts[package.dir], package.dir, false, Dict{String,String}()), files)
        for (name, triggers) in sort!(collect(package.extensions); by=first)
            entry = _extension_entry(package, name)
            haskey(sources, entry) || continue
            add!(:extension, entry, Context(hosts[package.dir], package.dir, false, triggers),
                 filter(owned(package.dir), _reach(entry, syntax; followed_only=false)); extension=name)
        end
    end

    # Test files are analyzed in their package's test environment. Each package's
    # runtests.jl comes first, so the files it includes statically need no units of their own.
    # A nested runtests.jl that one of them includes statically is part of its unit; another
    # is a driver unit run by the nearest one above it.
    covering = Dict{String,String}()
    tests = Dict{String,Vector{String}}()
    for source in inventory.sources
        source.path in covered && continue
        source.kind === :test && source.project in (source.owner, joinpath(source.owner, "test")) &&
            push!(get!(tests, source.owner, String[]), source.path)
    end
    for owner in sort!(collect(keys(tests)))
        files = tests[owner]
        context = _test_context(owner)
        for driver in sort!(filter(file -> basename(file) == "runtests.jl", files); by=length)
            driver in covered && continue
            expected = filter(file -> !(file in covered), _reach(driver, syntax; followed_only=true))
            add!(:test, driver, context, expected; driver=_driver(driver, owner, covering))
            foreach(file -> covering[file] = driver, expected)
        end
        for (entry, expected) in _entries(filter(file -> !(file in covered), files), syntax)
            add!(:test, entry, context, expected; driver=_driver(entry, owner, covering))
        end
    end

    # Extension sources no extension includes: in `ext/Name/`, those of extension `Name`.
    for source in inventory.sources
        source.path in covered && continue
        source.kind === :extension && haskey(projects, source.owner) && ispackage(projects[source.owner]) || continue
        package = projects[source.owner]
        parts = splitpath(relpath(source.path, joinpath(package.dir, "ext")))
        name = length(parts) > 1 && haskey(package.extensions, first(parts)) &&
            !isempty(_extension_entry(package, first(parts))) ? first(parts) : ""
        triggers = isempty(name) ? Dict{String,String}() : package.extensions[name]
        add!(:orphan, source.path, Context(hosts[package.dir], package.dir, false, triggers), [source.path];
             extension=name)
    end

    # Everything else is a script, analyzed in its nearest environment.
    scripts = Dict{Context,Vector{String}}()
    for source in inventory.sources
        source.path in covered && continue
        context = !isempty(source.owner) && source.project == source.owner ? _test_context(source.owner) :
            Context(source.project, "", false, Dict{String,String}())
        push!(get!(scripts, context, String[]), source.path)
    end
    for context in sort!(collect(keys(scripts)); by=context -> context.project)
        for (entry, expected) in _entries(scripts[context], syntax)
            add!(:script, entry, context, expected)
        end
    end
    sort!(units; by=unit -> (unit.entry, unit.extension))
    return _imports!(_configure(units, config, root), syntax, inventory)
end

"""
Give the contexts of scripts and tests the packages their files import without their
projects declaring them, as code does that runs with another project active or relies on
its workspace: packages of the workspace from their directories, others from the registry.
Where several packages of the workspace have a name, the first tier that has it decides: the
packages the sweep analyzes, then those of the configuration's directory it leaves out, then those
the configuration excludes, as a fixture's copy of a package may be. Several packages of that
tier leave the name to the registry.
"""
function _imports!(units::Vector{Unit}, syntax::Dict{String,Syntax}, inventory::Inventory)
    workspace = Dict{String,String}()
    for tier in [[filter(ispackage, inventory.projects)]; inventory.available]
        names = [project.name for project in tier]
        for project in tier
            get!(workspace, project.name, count(==(project.name), names) == 1 ? project.dir : "")
        end
    end
    # Other modules the tree defines, loaded through `LOAD_PATH`, say, are not packages to look up.
    defined = setdiff(Set(name for facts in values(syntax) for name in facts.modules), keys(workspace))
    available = union(Set(readdir(Sys.STDLIB)), ("Base", "Core", "Main"), defined)
    imported = Dict{Context,Set{String}}()
    for unit in units
        unit.kind in (:script, :test) || continue
        files = union((_reach(file, syntax; followed_only=true) for file in [unit.entry; unit.overrides.setup])...)
        union!(get!(imported, unit.context, Set{String}()),
               (name for file in files if haskey(syntax, file) for name in syntax[file].imports))
    end
    extended = Dict{Context,Context}()
    for (context, names) in imported
        loadable = try
            _loadable(context)
        catch
            continue   # preparing the environment reports what is wrong with its projects
        end
        undeclared = setdiff(names, loadable, available)
        isempty(undeclared) && continue
        extended[context] = Context(context.project, context.owner, context.test, context.triggers,
                                    Dict(name => get(workspace, name, "") for name in undeclared))
    end
    return [haskey(extended, unit.context) && unit.kind in (:script, :test) ?
            Unit(unit.id, unit.kind, unit.entry, extended[unit.context], unit.expected, unit.driver, unit.extension,
                 unit.overrides, unit.notes) : unit for unit in units]
end

"""
The project whose environment `package` loads in: that of an enclosing project that sources it by
path, if it leaves the source of a dependency to that project, which is the dependency or sources
it, as a test-only package that its parent's tests load does; else its own.
"""
function _host(package::Project, projects::Dict{String,Project})
    data = TOML.tryparsefile(package.file)
    data isa AbstractDict || return package.dir
    deps, own = get(data, "deps", Dict()), get(data, "sources", Dict())
    directory = package.dir
    while dirname(directory) != directory
        directory = dirname(directory)
        haskey(projects, directory) || continue
        host = TOML.tryparsefile(projects[directory].file)
        host isa AbstractDict || continue
        sources = get(host, "sources", Dict())
        any(source -> source isa AbstractDict && get(source, "path", nothing) isa String &&
                      _absolute(directory, source["path"]) == package.dir, values(sources)) || continue
        declared = merge((get(host, section, Dict()) for section in ("deps", "weakdeps", "extras"))...)
        provided(name, uuid) = !haskey(own, name) &&
            (get(host, "name", nothing) == name && get(host, "uuid", nothing) == uuid ||
             haskey(sources, name) && get(declared, name, nothing) == uuid)
        return any(((name, uuid),) -> provided(name, uuid), deps) ? directory : package.dir
    end
    return package.dir
end

"Packages a source can name in `pkgdir(Name)` and `pathof(Name)`: its owner, statically."
function _packages(source::Source, projects::Dict{String,Project})
    owner = get(projects, source.owner, nothing)
    return owner === nothing || isempty(owner.name) ? Dict{String,Project}() : Dict(owner.name => owner)
end

"Whether `rule` of `config` selects the unit whose entry is `entry`."
_selects(rule::ContextRule, config::Config, entry::String) = occursin(rule.pattern, _slash(relpath(entry, config.directory)))

function _configure(units::Vector{Unit}, config::Config, root::String)
    for rule in config.contexts
        set(key, value, current) = key in rule.keys ? value : current
        for (i, unit) in pairs(units)
            _selects(rule, config, unit.entry) || continue
            (; id, kind, context, driver) = unit
            # Only the generated entries of tests and scripts include setup files.
            loaded = kind in (:package, :extension, :orphan)
            if "project" in rule.keys && loaded
                context = Context(rule.project, context.owner, context.test, context.triggers)
            elseif "project" in rule.keys
                # A test or script runs in the configured environment alone: a script outside its package's tests.
                context = Context(rule.project, "", false, Dict{String,String}())
                id, kind, driver = _unit_id(:script, unit.entry, root), :script, ""
            end
            current = unit.overrides
            ignored = "$(config.file): setup does not apply to $(kind) analysis, which loads the package itself"
            notes = loaded && !isempty(rule.setup) ? sort!(union(unit.notes, [ignored])) : unit.notes
            overrides = Overrides(loaded ? current.setup : set("setup", rule.setup, current.setup),
                                  set("args", rule.args, current.args), merge(current.env, rule.env),
                                  set("jetls_config", rule.jetls_config, current.jetls_config))
            units[i] = Unit(id, kind, unit.entry, context, unit.expected, driver, unit.extension, overrides, notes)
        end
    end
    return units
end
