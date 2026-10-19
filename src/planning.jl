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
test directory, or the driver unit covering that file when another driver includes it.
"""
function _driver(file::String, owner::String, covering::Dict{String,String})
    tests = joinpath(owner, "test")
    directory = dirname(file)
    while _within(directory, tests)
        candidate = joinpath(directory, "runtests.jl")
        candidate != file && haskey(covering, candidate) && return covering[candidate]
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

"The include facts of every inventoried source."
source_syntax(inventory::Inventory) =
    let projects = Dict(project.dir => project for project in inventory.projects)
        Dict(source.path => parse_source(source.path, _package_dirs(source, projects)) for source in inventory.sources)
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

Includes are found by parsing, without executing any code.
"""
function plan(inventory::Inventory, config::Config=Config(); syntax::Dict{String,Syntax}=source_syntax(inventory))::Vector{Unit}
    root = inventory.root
    sources = Dict(source.path => source for source in inventory.sources)
    projects = Dict(project.dir => project for project in inventory.projects)
    notes(files) = sort!(unique!(reduce(vcat, (syntax[file].notes for file in files if haskey(syntax, file)); init=String[])))
    units = Unit[]
    covered = Set{String}()
    function add!(kind, entry, context, expected; driver="", extension="")
        expected = sort!(collect(filter(file -> haskey(sources, file), expected)))
        entry in expected || push!(expected, entry)
        union!(covered, expected)
        push!(units, Unit(_unit_id(kind, entry, root, extension), kind, entry, context, expected,
                          driver, extension, Overrides(), notes(expected)))
    end
    owned(owner) = file -> haskey(sources, file) && sources[file].owner == owner

    for package in sort!(filter(ispackage, inventory.projects); by=project -> project.dir)
        haskey(sources, package.entry) || continue
        context = Context(package.dir, package.dir, false, Dict{String,String}())
        files = union(filter(owned(package.dir), _reach(package.entry, syntax; followed_only=false)),
                      (s.path for s in inventory.sources if s.owner == package.dir && s.kind === :package))
        add!(:package, package.entry, context, files)
        for (name, triggers) in sort!(collect(package.extensions); by=first)
            entry = _extension_entry(package, name)
            haskey(sources, entry) || continue
            add!(:extension, entry, Context(package.dir, package.dir, false, triggers),
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
        add!(:orphan, source.path, Context(package.dir, package.dir, false, triggers), [source.path]; extension=name)
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
"""
function _imports!(units::Vector{Unit}, syntax::Dict{String,Syntax}, inventory::Inventory)
    names = [project.name for project in inventory.projects if ispackage(project)]
    workspace = Dict(project.name => project.dir for project in inventory.projects
                     if ispackage(project) && count(==(project.name), names) == 1)
    available = union(Set(readdir(Sys.STDLIB)), ("Base", "Core", "Main"))
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

"Directories of packages a source can name in `pkgdir(Name)`: its owner, statically."
function _package_dirs(source::Source, projects::Dict{String,Project})
    owner = get(projects, source.owner, nothing)
    return owner === nothing || isempty(owner.name) ? Dict{String,String}() : Dict(owner.name => owner.dir)
end

function _configure(units::Vector{Unit}, config::Config, root::String)
    for rule in config.contexts
        matched = false
        set(key, value, current) = key in rule.keys ? value : current
        for (i, unit) in pairs(units)
            occursin(rule.pattern, _slash(relpath(unit.entry, root))) || continue
            matched = true
            context = unit.context
            "project" in rule.keys && (context = Context(rule.project, context.owner, context.test, context.triggers))
            current = unit.overrides
            overrides = Overrides(set("setup", rule.setup, current.setup), set("args", rule.args, current.args),
                                  merge(current.env, rule.env), set("jetls_config", rule.jetls_config, current.jetls_config))
            units[i] = Unit(unit.id, unit.kind, unit.entry, context, unit.expected, unit.driver,
                            unit.extension, overrides, unit.notes)
        end
        matched || throw(ArgumentError("$(config.file): [[context]] match $(repr(rule.match)) selects no unit"))
    end
    return units
end
