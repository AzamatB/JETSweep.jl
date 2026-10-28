const _PRUNED = Set(["node_modules", "__pycache__"])
const _PROJECT_FILES = ("JuliaProject.toml", "Project.toml")

_slash(path::AbstractString) = replace(String(path), '\\' => '/')

function _within(path::AbstractString, directory::AbstractString)
    relative = relpath(path, directory)
    return !isabspath(relative) && first(splitpath(relative)) != ".."
end

"Translate a user glob: `*` and `?` stay within a path segment, `**` crosses segments."
function _glob(pattern::AbstractString)
    io = IOBuffer()
    print(io, '^')
    chars = collect(_slash(pattern))
    i = 1
    while i <= length(chars)
        c = chars[i]
        if c == '*' && get(chars, i + 1, ' ') == '*'
            i += 1
            if get(chars, i + 1, ' ') == '/'
                i += 1
                print(io, "(?:.*/)?")
            else
                print(io, ".*")
            end
        elseif c == '*'
            print(io, "[^/]*")
        elseif c == '?'
            print(io, "[^/]")
        else
            c in ".+()[]{}^\$|\\" && print(io, '\\')
            print(io, c)
        end
        i += 1
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

"""
Translate exclusion globs, relative to a directory. A pattern containing `/`, or starting
with `/` or `./`, matches the whole relative path; any other pattern matches any path segment.
"""
function _exclusions(patterns::Vector{String})
    globs, anchored = Regex[], Bool[]
    for pattern in patterns
        pattern = rstrip(_slash(pattern), '/')
        rooted = startswith(pattern, '/') || startswith(pattern, "./")
        pattern = rooted ? lstrip(pattern[(startswith(pattern, "./") ? 3 : 2):end], '/') : pattern
        isempty(pattern) && continue
        push!(globs, _glob(pattern))
        push!(anchored, rooted || occursin('/', pattern))
    end
    return globs, anchored
end

"Whether a relative path matches an exclusion."
function _excluded(relative::String, patterns::Vector{Regex}, anchored::Vector{Bool})
    for (pattern, whole) in zip(patterns, anchored)
        if whole
            occursin(pattern, relative) && return true
        else
            any(segment -> occursin(pattern, segment), eachsplit(relative, '/')) && return true
        end
    end
    return false
end

# LibGit2 has no Julia wrappers for these stable C entry points.
struct _Git
    repository::LibGit2.GitRepo
    index::LibGit2.GitIndex
    root::String
end

function _open_git(directory::String)
    repository = LibGit2.GitRepo(directory)
    try
        return _Git(repository, LibGit2.GitIndex(repository), normpath(LibGit2.workdir(repository)))
    catch
        close(repository)
        rethrow()
    end
end

Base.close(git::_Git) = (close(git.index); close(git.repository))

function _tracked_below(git::_Git, relative::String)
    position = Ref{Csize_t}(0)
    status = ccall((:git_index_find_prefix, LibGit2.libgit2), Cint,
        (Ref{Csize_t}, Ptr{Cvoid}, Cstring), position, git.index, relative * "/")
    status == 0 && return true
    status == Cint(LibGit2.Error.ENOTFOUND) && return false
    error("LibGit2 index lookup failed with code $status")
end

function _ignored(git::_Git, relative::String)
    ignored = Ref{Cint}(0)
    status = ccall((:git_ignore_path_is_ignored, LibGit2.libgit2), Cint,
        (Ref{Cint}, Ptr{Cvoid}, Cstring), ignored, git.repository, relative)
    status == 0 || error("LibGit2 ignore lookup failed with code $status")
    return ignored[] != 0
end

"The reason Git rules exclude a path, or `nothing` when it is included."
function _git_exclusion(git::_Git, path::String, isdirectory::Bool, hidden::Bool,
                        include_ignored::Bool, tracked_only::Bool)
    relative = _slash(relpath(path, git.root))
    if isdirectory
        _tracked_below(git, relative) && return nothing
        hidden && return "hidden directory"
        tracked_only && return "untracked Git path"
        !include_ignored && _ignored(git, relative) && return "Git-ignored path"
    else
        status = LibGit2.status(git.repository, relative)
        status === nothing && return nothing
        status & (LibGit2.Consts.STATUS_WT_NEW | LibGit2.Consts.STATUS_IGNORED) == 0 && return nothing
        tracked_only && return "untracked Git path"
        !include_ignored && status & LibGit2.Consts.STATUS_IGNORED != 0 && return "Git-ignored path"
    end
    return nothing
end

function _read_project(file::String, issues::Vector{String})
    directory = dirname(file)
    data = try
        TOML.parsefile(file)
    catch err
        push!(issues, "$file: cannot parse project: $(sprint(showerror, err))")
        return Project(directory, file, "", "", "", Dict{String,Dict{String,String}}())
    end
    name, uuid = get(data, "name", ""), get(data, "uuid", "")
    if !(name isa String && uuid isa String)
        push!(issues, "$file: project name and UUID must be strings")
        name = name isa String ? name : ""
        uuid = ""
    elseif !isempty(uuid) && tryparse(UUID, uuid) === nothing
        push!(issues, "$file: invalid project UUID $(repr(uuid))")
        uuid = ""
    end
    entry = ""
    if !isempty(name) && !isempty(uuid)
        # Julia's loader prefers the older `path` key over `entryfile`.
        path = get(data, "path", get(data, "entryfile", joinpath("src", "$name.jl")))
        if !(path isa String)
            push!(issues, "$file: package entry file must be a string")
        elseif isfile(joinpath(directory, path))
            entry = normpath(joinpath(directory, path))
        else
            push!(issues, "$file: package entry file does not exist: $path")
        end
    end
    dependencies = Dict{String,String}()
    for section in ("deps", "weakdeps")
        table = get(data, section, Dict{String,Any}())
        table isa AbstractDict || (push!(issues, "$file: [$section] must be a table"); continue)
        for (dependency, id) in table
            id isa String && tryparse(UUID, id) !== nothing ?
                (dependencies[dependency] = id) :
                push!(issues, "$file: invalid UUID for $dependency in [$section]")
        end
    end
    extensions = Dict{String,Dict{String,String}}()
    table = get(data, "extensions", Dict{String,Any}())
    table isa AbstractDict || (push!(issues, "$file: [extensions] must be a table"); table = Dict())
    for (extension, triggers) in table
        triggers = triggers isa String ? [triggers] : triggers
        if !(triggers isa Vector && !isempty(triggers) && all(t -> t isa String, triggers))
            push!(issues, "$file: extension $extension must name its trigger packages")
            continue
        end
        unknown = filter(t -> !haskey(dependencies, t), triggers)
        isempty(unknown) ||
            push!(issues, "$file: extension $extension triggers lack declared UUIDs: $(join(unknown, ", "))")
        extensions[extension] = Dict(t => get(dependencies, t, "") for t in triggers)
    end
    return Project(directory, file, name, uuid, entry, extensions)
end

"The start of a `CACHEDIR.TAG` file, which marks its directory as a cache (https://bford.info/cachedir/)."
const _CACHE_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"

"Whether a directory is tagged as a cache, as JETSweep tags its report directories."
function _cache_tagged(directory::String)
    tag = joinpath(directory, "CACHEDIR.TAG")
    return try
        isfile(tag) && String(read(tag, ncodeunits(_CACHE_SIGNATURE))) == _CACHE_SIGNATURE
    catch
        false
    end
end

"`ispath` throws for unreadable paths and symlink loops; treat those as absent."
_ispath(path::String) = try ispath(path) catch; false end

"""
    discover(root; exclude=String[], config=Config(), output="", include_ignored=false, tracked_only=false)

Recursively inventory the Julia projects and source files below `root`. Inside Git
repositories, LibGit2 applies each repository's ignore rules, including nested
repositories, and files Git tracks are kept even when ignored. Hidden directories are
skipped unless Git tracks files inside them, as are `node_modules` and `__pycache__`, and
always directories a `CACHEDIR.TAG` marks as caches, such as earlier reports. Symlinks are
not followed: inside the root they are aliases of what discovery reaches anyway, or of what
it excludes. `exclude` holds globs relative to `root`, and `config` exclusions relative to
its directory. `output` names a report directory to skip. The projects above `root`, as far
as Julia looks for an enclosing project, up to the home directory, are inventoried too, so
that a sweep of part of a project, such as a package's test directory, finds its sources in
the projects and packages they are in, as a sweep of the whole does.

The packages of directories the sweep leaves out are still inventoried, without their
sources or issues, as `available` packages that other code may load: those of excluded
directories, and, when `root` is part of the configuration's directory, those of the rest
of it.
"""
function discover(root::AbstractString; exclude::Vector{String}=String[], config::Config=Config(),
                  output::AbstractString="", include_ignored::Bool=false, tracked_only::Bool=false)::Inventory
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    root = realpath(root)
    output = isempty(output) ? "" : ispath(output) ? realpath(output) : abspath(output)
    workspace = !isempty(config.directory) && config.directory != root && _within(root, config.directory) ?
        config.directory : ""
    options, configured = _exclusions(exclude), _exclusions(config.exclude)
    excluded, issues, files = String[], String[], String[]
    # Project files by how far the sweep leaves them out: not, only the sweep, or the
    # configuration too, as `Inventory.available` orders its packages.
    project_files = [String[], String[], String[]]
    repositories = _Git[]

    function open_git(directory, issues)
        try
            push!(repositories, _open_git(directory))
            return last(repositories)
        catch err
            push!(issues, "$directory: cannot read Git repository, so its ignore rules are not applied: " *
                sprint(showerror, err))
            return nothing
        end
    end

    # The repository a directory is in, if any.
    function repository(directory, issues)
        ancestor = directory
        while true
            _ispath(joinpath(ancestor, ".git")) && return open_git(ancestor, issues)
            dirname(ancestor) == ancestor && return nothing
            ancestor = dirname(ancestor)
        end
    end

    # Why a path is left out, other than by pattern.
    function omission(path, name, git, isdirectory, hidden, issues)
        if !isempty(output) && _within(path, output)
            "report output"
        elseif isdirectory && _cache_tagged(path)
            "tagged cache directory"
        elseif isdirectory && name in _PRUNED
            "dependency or cache directory"
        elseif git !== nothing && !(isdirectory && _ispath(joinpath(path, ".git")))
            try
                _git_exclusion(git, path, isdirectory, hidden, include_ignored, tracked_only)
            catch err
                push!(issues, "$path: Git filtering failed, so the path is kept: $(sprint(showerror, err))")
                nothing
            end
        elseif hidden
            "hidden directory"
        end
    end

    # The directories left to walk, with the repository each is in and its tier.
    pending = Tuple{String,Union{Nothing,_Git},Int}[]

    # A directory the sweep leaves out, at `tier` 1, or that the configuration excludes, at 2,
    # is walked for its projects alone, with what goes wrong there left unreported: its
    # packages are still those of the workspace.
    function walk(directory::String, git::Union{Nothing,_Git}, tier::Int)
        reported = tier == 0 ? issues : String[]
        # Directory entries tell links and directories apart without a `stat` of each path,
        # which matters in large excluded trees.
        entries = try
            Base.Filesystem._readdirx(directory)
        catch err
            return push!(reported, "$directory: cannot list directory: $(sprint(showerror, err))")
        end
        directory != root && directory != workspace && any(entry -> entry.name == ".git", entries) &&
            (git = open_git(directory, reported))
        metadata = String[]
        for entry in entries
            name, path = entry.name, entry.path
            (name == ".git" || path == root) && continue
            link, isdirectory = try
                islink(entry), !islink(entry) && isdir(entry)
            catch err
                push!(reported, "$path: cannot read path: $(sprint(showerror, err))")
                continue
            end
            tier > 0 && !isdirectory && !(name in _PROJECT_FILES) && continue
            hidden = isdirectory && startswith(name, '.')
            patterned = link || tier == 2 ? 0 :
                !isempty(config.exclude) && _excluded(_slash(relpath(path, config.directory)), configured...) ? 2 :
                tier == 0 && _excluded(_slash(relpath(path, root)), options...) ? 1 : 0
            reason = link ? "symlink" : patterned > 0 ? "excluded by pattern" :
                omission(path, name, git, isdirectory, hidden, reported)
            if reason !== nothing
                tier == 0 && push!(excluded, "$path ($reason)")
                patterned > 0 && isdirectory && omission(path, name, git, isdirectory, hidden, String[]) === nothing &&
                    push!(pending, (path, git, max(tier, patterned)))
            elseif isdirectory
                push!(pending, (path, git, tier))
            elseif tier == 0 && endswith(name, ".jl")
                push!(files, path)
            elseif name in _PROJECT_FILES
                push!(metadata, name)
            end
        end
        # Julia prefers JuliaProject.toml when both project files exist.
        for name in _PROJECT_FILES
            name in metadata && (push!(project_files[tier + 1], joinpath(directory, name)); break)
        end
        return nothing
    end

    try
        push!(pending, (root, repository(root, issues), 0))
        isempty(workspace) || push!(pending, (workspace, repository(workspace, String[]), 1))
        while !isempty(pending)
            walk(pop!(pending)...)
        end
    finally
        foreach(close, repositories)
    end
    # The projects above the root, as `--project=@.` looks for one.
    directory = root
    while directory != homedir() && dirname(directory) != directory
        directory = dirname(directory)
        found = findfirst(name -> isfile(joinpath(directory, name)), _PROJECT_FILES)
        found === nothing || push!(project_files[1], joinpath(directory, _PROJECT_FILES[found]))
    end
    projects = [_read_project(file, issues) for file in sort!(project_files[1])]
    available = [filter(project -> ispackage(project) && !(project.file in project_files[1]),
                        [_read_project(file, String[]) for file in sort!(tier)]) for tier in project_files[2:3]]
    # Deepest projects first, so the first match is the nearest enclosing project. A named
    # project bounds package ownership even when its metadata is otherwise broken.
    nearest = sort(projects; by=project -> (-length(project.dir), project.dir))
    sources = map(sort!(files)) do path
        enclosing = filter(project -> _within(path, project.dir), nearest)
        index = findfirst(project -> !isempty(project.name), enclosing)
        owner = index === nothing ? nothing : enclosing[index]
        Source(path, _source_kind(path, owner), isempty(enclosing) ? "" : first(enclosing).dir,
               owner === nothing ? "" : owner.dir)
    end
    return Inventory(root, projects, sources, available, sort!(excluded), sort!(unique!(issues)))
end

function _source_kind(path::String, owner::Union{Nothing,Project})
    owner === nothing && return :script
    path == owner.entry && return :package
    top = first(splitpath(relpath(path, owner.dir)))
    return top == "src" ? :package : top == "ext" ? :extension : top == "test" ? :test : :script
end
