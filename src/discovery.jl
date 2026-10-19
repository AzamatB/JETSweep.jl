const _PRUNED_DIRECTORIES = Set([
    ".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv",
    ".tox", ".mypy_cache", ".pytest_cache", ".cache", ".julia", ".jetsweep",
    ".jetsweep-results", ".quality-audit", ".jetls-audit", ".inference-audit",
])

_slash(path::AbstractString) = replace(String(path), '\\' => '/')
function _within(path::AbstractString, directory::AbstractString)
    relative = relpath(path, directory)
    return !isabspath(relative) && first(splitpath(relative)) != ".."
end

"Match an explicit user glob; Git ignore syntax is handled exclusively by LibGit2."
function _glob_regex(pattern::AbstractString)
    chars = collect(_slash(pattern))
    io = IOBuffer()
    print(io, '^')
    i = 1
    while i <= length(chars)
        c = chars[i]
        if c == '*'
            if i < length(chars) && chars[i + 1] == '*'
                i += 1
                if i < length(chars) && chars[i + 1] == '/'
                    i += 1
                    print(io, "(?:.*/)?")
                else
                    print(io, ".*")
                end
            else
                print(io, "[^/]*")
            end
        elseif c == '?'
            print(io, "[^/]")
        else
            c in ('.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\') && print(io, '\\')
            print(io, c)
        end
        i += 1
    end
    print(io, '$')
    return Regex(String(take!(io)))
end

function _explicit_exclusion(path::String, root::String, patterns::Vector{String})
    relative = _slash(relpath(path, root))
    for raw in patterns
        pattern = rstrip(_slash(raw), '/')
        isempty(pattern) && continue
        if !occursin('*', pattern) && !occursin('?', pattern)
            target = normpath(isabspath(raw) ? raw : joinpath(root, raw))
            _within(path, target) && return "explicit exclusion: $raw"
            !occursin('/', pattern) && pattern in split(relative, '/') && return "explicit exclusion: $raw"
        else
            candidate = isabspath(raw) ? _slash(path) : relative
            occursin(_glob_regex(pattern), candidate) && return "explicit exclusion: $raw"
            !occursin('/', pattern) && any(part -> occursin(_glob_regex(pattern), part), split(relative, '/')) && return "explicit exclusion: $raw"
        end
    end
    return ""
end

struct _DiscoveryGit
    repository::LibGit2.GitRepo
    index::LibGit2.GitIndex
    root::String
end

function _open_discovery_git(directory::String)
    repository = LibGit2.GitRepo(directory)
    try
        root = normpath(LibGit2.workdir(repository))
        index = LibGit2.GitIndex(repository)
        return _DiscoveryGit(repository, index, root)
    catch
        close(repository)
        rethrow()
    end
end

function _git_directory_tracked(state::_DiscoveryGit, relative::String)
    # LibGit2 has no Julia wrapper for this stable C API. Ask for an index
    # prefix without reading ABI-sensitive git_index_entry structures.
    position = Ref{Csize_t}(0)
    result = ccall((:git_index_find_prefix, LibGit2.libgit2), Cint,
                   (Ref{Csize_t}, Ptr{Cvoid}, Cstring), position, state.index, relative * "/")
    result == 0 && return true
    result == Cint(LibGit2.Error.ENOTFOUND) && return false
    throw(ErrorException("LibGit2 index-prefix lookup failed ($result)"))
end

function _git_ignored(state::_DiscoveryGit, relative::String)
    ignored = Ref{Cint}(0)
    result = ccall((:git_ignore_path_is_ignored, LibGit2.libgit2), Cint,
                   (Ref{Cint}, Ptr{Cvoid}, Cstring), ignored, state.repository, relative)
    result == 0 || throw(ErrorException("LibGit2 ignore lookup failed ($result)"))
    return ignored[] != 0
end

function _git_exclusion(state::_DiscoveryGit, path::String, directory::Bool;
                        include_ignored::Bool, include_untracked::Bool)
    relative = _slash(relpath(path, state.root))
    if directory
        _git_directory_tracked(state, relative) && return ""
        !include_untracked && return "untracked Git path"
        !include_ignored && _git_ignored(state, relative) && return "Git ignored path"
    else
        status = LibGit2.status(state.repository, relative)
        status === nothing && return ""
        status & (LibGit2.Consts.STATUS_WT_NEW | LibGit2.Consts.STATUS_IGNORED) == 0 && return ""
        !include_untracked && return "untracked Git path"
        !include_ignored && status & LibGit2.Consts.STATUS_IGNORED != 0 && return "Git ignored path"
    end
    return ""
end

function _project_record(file::String, issues::Vector{String})
    directory = dirname(file)
    data = try
        TOML.parsefile(file)
    catch err
        push!(issues, "$file: project parse failed: $(sprint(showerror, err))")
        return ProjectRecord(path=directory)
    end
    field(name, fallback="") = get(data, name, fallback)
    name = field("name")
    uuid = field("uuid")
    if !(name isa String && uuid isa String)
        push!(issues, "$file: project name and UUID must be strings")
        return ProjectRecord(path=directory)
    end
    valid_uuid = !isempty(uuid)
    if valid_uuid
        try
            UUID(uuid)
        catch
            valid_uuid = false
            push!(issues, "$file: invalid project UUID $uuid")
        end
    end
    dependencies = Dict{String,Dict{String,String}}()
    for section in ("deps", "weakdeps")
        table = field(section, Dict{String,Any}())
        result = Dict{String,String}()
        if table isa AbstractDict
            for (key, value) in table
                if value isa String && tryparse(UUID, value) !== nothing
                    result[String(key)] = value
                else
                    push!(issues, "$file: invalid UUID in [$section] for $key")
                end
            end
        else
            push!(issues, "$file: [$section] must be a table")
        end
        dependencies[section] = result
    end
    extensions = Dict{String,Vector{String}}()
    table = field("extensions", Dict{String,Any}())
    if table isa AbstractDict
        for (key, value) in table
            if value isa String
                extensions[String(key)] = [value]
            elseif value isa Vector && all(x -> x isa String, value)
                extensions[String(key)] = String[value...]
                isempty(value) && push!(issues, "$file: extension $key declares no dependency triggers")
            else
                push!(issues, "$file: extension $key must name one or more dependency triggers")
            end
        end
    else
        push!(issues, "$file: [extensions] must be a table")
    end
    entry = ""
    if !isempty(name) && valid_uuid
        # Match Julia's loader: the older `path` key takes precedence over `entryfile`.
        requested = field("path", field("entryfile", joinpath("src", "$name.jl")))
        if requested isa String
            entry = normpath(joinpath(directory, requested))
            isfile(entry) || push!(issues, "$file: package entry file does not exist: $entry")
        else
            push!(issues, "$file: package entryfile must be a string")
        end
    end
    return ProjectRecord(path=directory, name=name, uuid=uuid, entry=entry,
                         deps=dependencies["deps"], weakdeps=dependencies["weakdeps"], extensions=extensions)
end

"""
    discover(root; excludes=String[], output="", include_ignored=false, include_untracked=true)

Recursively inventory Julia projects and sources, including unnamed environments,
nested repositories, and hidden source directories such as `.pkg`. Git repositories
use LibGit2's actual ignore rules; tracked files remain included even when ignored.
Outside Git, every source is included unless explicitly excluded. Directory symlinks
within the root are followed once; cycles, aliases, and links outside the root are
recorded as exclusions. Excluded directory entries describe their complete subtree.
"""
function discover(root::AbstractString; excludes::Vector{String}=String[], output::String="",
                  include_ignored::Bool=false, include_untracked::Bool=true)::Inventory
    isdir(root) || throw(ArgumentError("discovery root is not a directory: $root"))
    directory = realpath(abspath(root))
    destination = isempty(output) ? "" : ispath(output) ? realpath(output) : abspath(output)
    excluded = String[]
    issues = String[]
    sources = String[]
    project_files = String[]
    visited = Set{String}()
    repositories = Dict{String,_DiscoveryGit}()

    function open_repository(path)
        haskey(repositories, path) && return repositories[path]
        try
            state = _open_discovery_git(path)
            repositories[path] = state
            return state
        catch err
            push!(issues, "$path: cannot read Git repository; walking without Git filtering: $(sprint(showerror, err))")
            return nothing
        end
    end

    function walk(path, inherited_git)
        canonical = try
            realpath(path)
        catch err
            push!(issues, "$path: cannot resolve directory: $(sprint(showerror, err))")
            return
        end
        if canonical in visited
            push!(excluded, "$path (directory symlink cycle or alias)")
            return
        end
        push!(visited, canonical)
        state = ispath(joinpath(path, ".git")) ? open_repository(path) : inherited_git
        children = try
            readdir(path; join=true)
        catch err
            push!(issues, "$path: cannot list directory: $(sprint(showerror, err))")
            return
        end
        # Prefer real directories over aliases to keep source identities stable.
        sort!(children; by=p -> (islink(p), p))
        accepted = String[]
        for child in children
            isdirectory = isdir(child)
            reason = _explicit_exclusion(child, directory, excludes)
            if isempty(reason) && !isempty(destination) && _within(child, destination)
                reason = "analysis output directory"
            end
            if isempty(reason) && isdirectory && basename(child) in _PRUNED_DIRECTORIES
                reason = "default metadata, cache, or audit-output exclusion"
            end
            if isempty(reason) && islink(child)
                if !ispath(child)
                    reason = "broken symbolic link"
                elseif !_within(realpath(child), directory)
                    reason = "symbolic link outside discovery root"
                end
            end
            # A nested repository owns its own ignore rules.
            nested_git = isdirectory && ispath(joinpath(child, ".git"))
            if isempty(reason) && state !== nothing && !nested_git
                try
                    reason = _git_exclusion(state, child, isdirectory;
                                            include_ignored, include_untracked)
                catch err
                    push!(issues, "$child: Git filtering failed; including path: $(sprint(showerror, err))")
                end
            end
            if !isempty(reason)
                push!(excluded, "$child ($reason)")
            elseif isdirectory
                walk(child, state)
            elseif isfile(child)
                push!(accepted, child)
                endswith(child, ".jl") && push!(sources, child)
            end
        end
        preferred = joinpath(path, "JuliaProject.toml")
        fallback = joinpath(path, "Project.toml")
        if preferred in accepted
            push!(project_files, preferred)
            fallback in accepted && push!(excluded, "$fallback (shadowed by JuliaProject.toml)")
        elseif fallback in accepted
            push!(project_files, fallback)
        end
    end

    parent_git = nothing
    ancestor = directory
    while true
        if ispath(joinpath(ancestor, ".git"))
            parent_git = open_repository(ancestor)
            break
        end
        dirname(ancestor) == ancestor && break
        ancestor = dirname(ancestor)
    end
    try
        walk(directory, parent_git)
    finally
        for state in values(repositories)
            close(state.index)
            close(state.repository)
        end
    end
    projects = [_project_record(file, issues) for file in sort!(project_files)]
    by_depth = sort(projects; by=p -> (-length(splitpath(p.path)), p.path))
    files = SourceRecord[]
    for source in sort!(sources)
        parents = filter(p -> _within(source, p.path), by_depth)
        nearest = isempty(parents) ? nothing : first(parents)
        # An unnamed test/docs environment inherits package ownership. A named
        # nested project is a package boundary even if its metadata is broken.
        owner_index = findfirst(p -> !isempty(p.name) || !isempty(p.entry), parents)
        owner = owner_index === nothing ? nothing : parents[owner_index]
        owner_path = owner === nothing ? "" : owner.path
        relative = relpath(source, isempty(owner_path) ? directory : owner_path)
        parts = splitpath(relative)
        kind = if owner !== nothing && (source == owner.entry || first(parts) == "src")
            :package_source
        elseif owner !== nothing && first(parts) == "ext"
            :extension
        elseif any(part -> part in ("test", "tests"), parts)
            :test
        else
            :script
        end
        push!(files, SourceRecord(path=source, project=nearest === nothing ? "" : nearest.path,
                                 owner=owner_path, kind=kind))
    end
    return Inventory(directory, projects, files, sort!(unique!(excluded)), sort!(unique!(issues)))
end
