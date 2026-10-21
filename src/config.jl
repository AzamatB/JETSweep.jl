"A `[[context]]` table: settings for units whose entry matches a glob, relative to the configuration's `directory`."
struct ContextRule
    match::String
    pattern::Regex
    "The keys the table sets; only those override earlier tables and the planned context."
    keys::Set{String}
    project::String
    setup::Vector{String}
    args::Vector{String}
    env::Dict{String,String}
    jetls_config::String
end

"Settings from a `.JETSweep.toml`: extra exclusions and per-unit context overrides."
struct Config
    file::String
    """
    The directory the globs are relative to: the file's when the swept directory is in it, as
    for a sweep of part of a workspace, else the swept directory. It holds every swept path.
    """
    directory::String
    exclude::Vector{String}
    contexts::Vector{ContextRule}
end

Config() = Config("", "", String[], ContextRule[])

function _strings(value, key::String, file::String)
    value isa Vector && all(item -> item isa String, value) ||
        throw(ArgumentError("$file: `$key` must be an array of strings"))
    return String[value...]
end

"An absolute, normalized path without a trailing separator."
_absolute(base::String, path::String) = (path = normpath(abspath(base, path)); length(path) > 1 ? String(rstrip(path, '/')) : path)

"""
    read_config(root, file="") -> Config

Read `file`, or `root/.JETSweep.toml` when it exists. `project`, `setup` and `jetls_config`
are paths relative to the file. Globs are relative to the file's directory when `root` is in
it, else to `root`: `exclude` patterns follow the `--exclude` rules there, and each `match` is
a glob a unit's entry path must match whole. `setup` applies to tests and scripts, not to
package, extension and orphan analyses, which load the package itself. When several
`[[context]]` tables match a unit, each key a later table sets overrides it, except `env`,
whose variables merge.

```toml
exclude = ["vendor", "**/generated/*.jl"]

[[context]]
match = "tools/check.jl"        # units whose entry file matches
project = "tools"               # analyze in this environment
setup = ["tools/setup.jl"]      # files included before the entry
args = ["--fast"]               # ARGS during analysis
env = { MODE = "analysis" }     # environment variables during analysis
jetls_config = "tools/.JETLSConfig.toml"
```
"""
function read_config(root::AbstractString, file::AbstractString="")
    explicit = !isempty(file)
    candidate = explicit ? abspath(file) : joinpath(root, ".JETSweep.toml")
    isfile(candidate) || (explicit ? throw(ArgumentError("configuration file does not exist: $candidate")) : return Config())
    # Globs match real paths, as discovery finds them.
    config_file = joinpath(realpath(dirname(candidate)), basename(candidate))
    data = TOML.parsefile(config_file)
    unknown = setdiff(keys(data), ("exclude", "context"))
    isempty(unknown) || throw(ArgumentError("$config_file: unknown keys $(join(sort!(collect(unknown)), ", "))"))
    base = dirname(config_file)
    root = ispath(root) ? realpath(root) : abspath(root)
    directory = _within(root, base) ? base : root
    exclude = _strings(get(data, "exclude", String[]), "exclude", config_file)
    tables = get(data, "context", Any[])
    tables isa Vector && all(table -> table isa AbstractDict, tables) ||
        throw(ArgumentError("$config_file: `context` must be an array of tables, [[context]]"))
    contexts = map(tables) do table
        extra = setdiff(keys(table), ("match", "project", "setup", "args", "env", "jetls_config"))
        isempty(extra) || throw(ArgumentError("$config_file: unknown [[context]] keys $(join(sort!(collect(extra)), ", "))"))
        match = get(table, "match", nothing)
        match isa String || throw(ArgumentError("$config_file: each [[context]] needs a `match` glob"))
        project = get(table, "project", "")
        project isa String || throw(ArgumentError("$config_file: `project` must be a path"))
        if haskey(table, "project")
            project = _absolute(base, project)
            basename(project) in _PROJECT_FILES && (project = dirname(project))
            any(isfile, joinpath.(project, _PROJECT_FILES)) ||
                throw(ArgumentError("$config_file: no Julia project at $project"))
        end
        setup = [_absolute(base, path) for path in _strings(get(table, "setup", String[]), "setup", config_file)]
        for path in setup
            isfile(path) || throw(ArgumentError("$config_file: setup file does not exist: $path"))
        end
        env = get(table, "env", Dict{String,Any}())
        env isa AbstractDict && all(value -> value isa String, values(env)) ||
            throw(ArgumentError("$config_file: `env` must be a table of strings"))
        jetls_config = get(table, "jetls_config", "")
        jetls_config isa String || throw(ArgumentError("$config_file: `jetls_config` must be a path"))
        if haskey(table, "jetls_config")
            jetls_config = _absolute(base, jetls_config)
            isfile(jetls_config) || throw(ArgumentError("$config_file: JETLS configuration does not exist: $jetls_config"))
        end
        ContextRule(match, _glob(match), Set{String}(keys(table)), project, setup,
                    _strings(get(table, "args", String[]), "args", config_file), Dict{String,String}(env), jetls_config)
    end
    return Config(config_file, directory, exclude, contexts)
end
