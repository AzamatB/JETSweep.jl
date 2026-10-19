_unit_id(kind::Symbol, entry::String, root::String, extension::String="") =
    string(kind, '-', bytes2hex(sha256(string(_slash(relpath(entry, root)), '\0', extension)))[1:12])

"Files reachable from `entry` through statically resolved includes, optionally only those analysis follows."
function _reach(entry::String, syntax::Dict{String,Syntax}; followed_only::Bool)
    seen = Set{String}()
    pending = [entry]
    while !isempty(pending)
        file = pop!(pending)
        file in seen && continue
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
Select entry files that cover `files`: files no other file in the set includes come first,
each covering what it reaches; files left in include cycles become entries in path order.
"""
function _entries(files::Vector{String}, syntax::Dict{String,Syntax})
    remaining = Set(files)
    entries = Pair{String,Vector{String}}[]
    while !isempty(remaining)
        included = Set{String}()
        for file in remaining, include in syntax[file].includes
            include.followed && include.target != file && push!(included, include.target)
        end
        roots = sort!([file for file in remaining if !(file in included)])
        isempty(roots) && (roots = [minimum(remaining)])
        for root in roots
            root in remaining || continue
            covered = sort!(collect(intersect(_reach(root, syntax; followed_only=true), remaining)))
            setdiff!(remaining, covered)
            push!(entries, root => covered)
        end
    end
    return entries
end

"The nearest `runtests.jl` above `file` within its package's test directory."
function _driver(file::String, owner::String, sources::Dict{String,Source})
    tests = joinpath(owner, "test")
    directory = dirname(file)
    while _within(directory, tests)
        candidate = joinpath(directory, "runtests.jl")
        candidate != file && haskey(sources, candidate) && return candidate
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

"""
    plan(inventory, config=Config()) -> Vector{Unit}

Partition the inventory into analysis units:

- each package entry and each declared extension, covering the files they include;
- each package's `test/runtests.jl`, covering the files analysis follows from it, and
  every other test file as its own unit after a prelude of the driver's definitions;
- scripts, grouped by the files they include, in their nearest environment;
- package sources that no entry includes, with the package's bindings in scope.

Includes are found by parsing, without executing any code.
"""
function plan(inventory::Inventory, config::Config=Config())::Vector{Unit}
    root = inventory.root
    sources = Dict(source.path => source for source in inventory.sources)
    projects = Dict(project.dir => project for project in inventory.projects)
    syntax = Dict(source.path => parse_source(source.path, _package_dirs(source, projects))
                  for source in inventory.sources)
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
        context = Context(package.dir, package.dir, false, Dict{String,String}())
        add!(:package, package.entry, context,
             filter(owned(package.dir), _reach(package.entry, syntax; followed_only=false)))
        for (name, triggers) in sort!(collect(package.extensions); by=first)
            entry = _extension_entry(package, name)
            isempty(entry) && continue
            add!(:extension, entry, Context(package.dir, package.dir, false, triggers),
                 filter(owned(package.dir), _reach(entry, syntax; followed_only=false)); extension=name)
        end
    end

    uncovered = filter(source -> !(source.path in covered), inventory.sources)
    # Test files are analyzed in their package's test environment. Each package's
    # runtests.jl comes first, so the files it includes statically need no units of their own.
    tests = Dict{String,Vector{String}}()
    for source in uncovered
        source.kind === :test && source.project in (source.owner, joinpath(source.owner, "test")) &&
            push!(get!(tests, source.owner, String[]), source.path)
    end
    for owner in sort!(collect(keys(tests)))
        files = tests[owner]
        project = isfile(joinpath(owner, "test", "Project.toml")) || isfile(joinpath(owner, "test", "JuliaProject.toml")) ?
            joinpath(owner, "test") : owner
        context = Context(project, owner, true, Dict{String,String}())
        drivers = sort!(filter(file -> basename(file) == "runtests.jl", files); by=length)
        for driver in drivers
            driver in covered && continue
            add!(:test, driver, context, filter(file -> !(file in covered), _reach(driver, syntax; followed_only=true)))
        end
        for (entry, expected) in _entries(filter(file -> !(file in covered), files), syntax)
            add!(:test, entry, context, expected; driver=_driver(entry, owner, sources))
        end
    end

    uncovered = filter(source -> !(source.path in covered), inventory.sources)
    orphans = filter(source -> source.kind in (:package, :extension) && haskey(projects, source.owner) &&
                               ispackage(projects[source.owner]), uncovered)
    for source in orphans
        add!(:orphan, source.path, Context(source.owner, source.owner, false, Dict{String,String}()), [source.path])
    end

    # Everything else is a script, analyzed in its nearest environment. A script of a
    # package that has no environment of its own loads the package's dependencies.
    scripts = Dict{Context,Vector{String}}()
    for source in uncovered
        source.path in covered && continue
        context = Context(source.project, source.project == source.owner ? source.owner : "", false,
                          Dict{String,String}())
        push!(get!(scripts, context, String[]), source.path)
    end
    for context in sort!(collect(keys(scripts)); by=context -> context.project)
        for (entry, expected) in _entries(scripts[context], syntax)
            add!(:script, entry, context, expected)
        end
    end
    sort!(units; by=unit -> (unit.entry, unit.extension))
    return _configure(units, config, root)
end

"Directories of packages a source can name in `pkgdir(Name)`: its owner, statically."
function _package_dirs(source::Source, projects::Dict{String,Project})
    owner = get(projects, source.owner, nothing)
    return owner === nothing || isempty(owner.name) ? Dict{String,String}() : Dict(owner.name => owner.dir)
end

function _configure(units::Vector{Unit}, config::Config, root::String)
    for rule in config.contexts
        matched = false
        for (i, unit) in pairs(units)
            occursin(rule.pattern, _slash(relpath(unit.entry, root))) || continue
            matched = true
            context = isempty(rule.project) ? unit.context :
                Context(rule.project, unit.context.owner, unit.context.test, unit.context.triggers)
            units[i] = Unit(unit.id, unit.kind, unit.entry, context, unit.expected, unit.driver,
                            unit.extension, rule.overrides, unit.notes)
        end
        matched || throw(ArgumentError("$(config.file): [[context]] match $(repr(rule.match)) selects no unit"))
    end
    return units
end
