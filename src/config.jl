"A `[[context]]` table: overrides for units whose entry matches a root-relative glob."
struct ContextRule
    match::String
    pattern::Regex
    project::String
    overrides::Overrides
end

"Settings from a `.JETSweep.toml`: extra exclusions and per-unit context overrides."
struct Config
    file::String
    exclude::Vector{String}
    contexts::Vector{ContextRule}
end

Config() = Config("", String[], ContextRule[])

function _strings(value, key::String, file::String)
    value isa Vector && all(item -> item isa String, value) ||
        throw(ArgumentError("$file: `$key` must be an array of strings"))
    return String[value...]
end

"""
    read_config(root, file="") -> Config

Read `file`, or `root/.JETSweep.toml` when it exists. Paths in the file are relative to
its directory; `match` patterns are relative to `root`.

```toml
exclude = ["vendor", "**/generated/*.jl"]

[[context]]
match = "tools/check.jl"        # one or more units, by entry file
project = "tools"               # analyze in this environment
setup = ["tools/setup.jl"]      # files included before the entry
args = ["--fast"]               # ARGS during analysis
env = { MODE = "analysis" }     # environment variables during analysis
jetls_config = "tools/.JETLSConfig.toml"
```
"""
function read_config(root::AbstractString, file::AbstractString="")
    file = isempty(file) ? joinpath(root, ".JETSweep.toml") : abspath(file)
    isfile(file) || (file == joinpath(root, ".JETSweep.toml") ? (return Config()) :
                     throw(ArgumentError("configuration file does not exist: $file")))
    data = TOML.parsefile(file)
    unknown = setdiff(keys(data), ("exclude", "context"))
    isempty(unknown) || throw(ArgumentError("$file: unknown keys $(join(sort!(collect(unknown)), ", "))"))
    base = dirname(file)
    exclude = _strings(get(data, "exclude", String[]), "exclude", file)
    tables = get(data, "context", Any[])
    tables isa Vector && all(table -> table isa AbstractDict, tables) ||
        throw(ArgumentError("$file: `context` must be an array of tables, [[context]]"))
    contexts = map(tables) do table
        unknown = setdiff(keys(table), ("match", "project", "setup", "args", "env", "jetls_config"))
        isempty(unknown) || throw(ArgumentError("$file: unknown [[context]] keys $(join(sort!(collect(unknown)), ", "))"))
        match = get(table, "match", nothing)
        match isa String || throw(ArgumentError("$file: each [[context]] needs a `match` glob"))
        project = get(table, "project", "")
        project isa String || throw(ArgumentError("$file: `project` must be a path"))
        if !isempty(project)
            project = abspath(base, project)
            basename(project) in _PROJECT_FILES && (project = dirname(project))
            any(name -> isfile(joinpath(project, name)), _PROJECT_FILES) ||
                throw(ArgumentError("$file: no Julia project at $project"))
        end
        setup = [abspath(base, path) for path in _strings(get(table, "setup", String[]), "setup", file)]
        for path in setup
            isfile(path) || throw(ArgumentError("$file: setup file does not exist: $path"))
        end
        env = get(table, "env", Dict{String,Any}())
        env isa AbstractDict && all(value -> value isa String, values(env)) ||
            throw(ArgumentError("$file: `env` must be a table of strings"))
        jetls_config = get(table, "jetls_config", "")
        jetls_config isa String || throw(ArgumentError("$file: `jetls_config` must be a path"))
        if !isempty(jetls_config)
            jetls_config = abspath(base, jetls_config)
            isfile(jetls_config) || throw(ArgumentError("$file: JETLS configuration does not exist: $jetls_config"))
        end
        overrides = Overrides(setup, _strings(get(table, "args", String[]), "args", file),
                              Dict{String,String}(env), jetls_config)
        ContextRule(match, _glob(match), project, overrides)
    end
    return Config(file, exclude, contexts)
end
