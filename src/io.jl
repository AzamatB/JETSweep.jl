file_digest(path::AbstractString) = open(io -> bytes2hex(sha256(io)), path)

function write_toml(path::AbstractString, value)
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        TOML.print(io, value; sorted=true)
        close(io)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary)
    end
    return path
end

context_dict(context::ContextSpec) = Dict{String,Any}(
    "project" => context.project, "setup" => context.setup,
    "arguments" => context.arguments, "variables" => context.variables,
    "configuration" => context.configuration, "test_entry" => context.test_entry,
    "containing_files" => context.containing_files)

job_dict(job::AnalysisJob) = Dict{String,Any}(
    "id" => job.id, "kind" => String(job.kind), "entry" => job.entry,
    "project" => job.project, "owner" => job.owner,
    "expected_files" => job.expected_files, "extension" => job.extension,
    "triggers" => job.triggers, "context" => context_dict(job.context),
    "issues" => job.issues, "blocking_issues" => job.blocking_issues)

function job_from_dict(value::AbstractDict)
    context = get(value, "context", Dict{String,Any}())
    strings(key) = String.(get(context, key, String[]))
    spec = ContextSpec(;
        project=String(get(context, "project", "")), setup=strings("setup"),
        arguments=strings("arguments"),
        variables=Dict{String,String}(get(context, "variables", Dict())),
        configuration=String(get(context, "configuration", "")),
        test_entry=String(get(context, "test_entry", "")),
        containing_files=strings("containing_files"))
    return AnalysisJob(;
        id=String(value["id"]), kind=Symbol(value["kind"]),
        entry=String(value["entry"]), project=String(value["project"]),
        owner=String(get(value, "owner", "")),
        expected_files=String.(get(value, "expected_files", String[])),
        extension=String(get(value, "extension", "")),
        triggers=Dict{String,String}(get(value, "triggers", Dict())),
        context=spec, issues=String.(get(value, "issues", String[])),
        blocking_issues=String.(get(value, "blocking_issues", String[])))
end

environment_dict(environment::EnvironmentResult) = Dict{String,Any}(
    "status" => String(environment.status), "project" => environment.project,
    "load_paths" => environment.load_paths, "message" => environment.message,
    "fingerprints" => environment.fingerprints, "tool_project" => environment.tool_project)

function environment_from_dict(value::AbstractDict)
    return EnvironmentResult(;
        status=Symbol(value["status"]), project=String(get(value, "project", "")),
        load_paths=String.(get(value, "load_paths", String[])),
        message=String(get(value, "message", "")),
        fingerprints=Dict{String,String}(get(value, "fingerprints", Dict())),
        tool_project=String(get(value, "tool_project", "")))
end

function inventory_dict(inventory::Inventory)
    return Dict{String,Any}(
        "root" => inventory.root,
        "projects" => [Dict{String,Any}("path" => p.path, "name" => p.name,
            "uuid" => p.uuid, "entry" => p.entry, "deps" => p.deps,
            "weakdeps" => p.weakdeps, "extensions" => p.extensions)
            for p in inventory.projects],
        "files" => [Dict("path" => f.path, "project" => f.project,
            "owner" => f.owner, "kind" => String(f.kind)) for f in inventory.files],
        "excluded" => inventory.excluded, "issues" => inventory.issues)
end

function input_snapshot(inventory::Inventory, jobs::Vector{AnalysisJob}; config::String="")
    paths = Set(file.path for file in inventory.files)
    directories = Set([inventory.root])
    union!(directories, (project.path for project in inventory.projects))
    for job in jobs
        for project in (job.project, job.owner, job.context.project)
            isempty(project) && continue
            push!(directories, isfile(project) ? dirname(project) : project)
        end
        for path in (job.context.setup..., job.context.containing_files...,
                     job.context.configuration, job.context.test_entry)
            isempty(path) || push!(paths, path)
        end
    end
    isempty(config) || push!(paths, abspath(config))
    tool_root = dirname(@__DIR__)
    push!(directories, tool_root)
    tool_project = _tool_project()
    tool_project === nothing || push!(directories, dirname(tool_project))
    for directory in directories
        isdir(directory) || continue
        # ProjectRecord.path is a directory. Keep both project filenames so a
        # newly introduced JuliaProject.toml or removed project is detectable.
        for path in readdir(directory; join=true)
            name = basename(path)
            if isfile(path) && (occursin(r"^(Julia)?Manifest(?:-v[0-9.]+)?\.toml$", name) ||
                    name in ("Project.toml", "JuliaProject.toml", "LocalPreferences.toml",
                             "JuliaLocalPreferences.toml", "Artifacts.toml", "JuliaArtifacts.toml",
                             ".JETLSConfig.toml", ".JETSweep.toml"))
                push!(paths, path)
            end
        end
        # Julia also permits a project to select a nonstandard manifest path.
        for name in ("JuliaProject.toml", "Project.toml")
            file = joinpath(directory, name)
            isfile(file) || continue
            data = try
                TOML.parsefile(file)
            catch
                # Malformed metadata itself remains fingerprinted; discovery and
                # environment preparation report its parse failure separately.
                continue
            end
            manifest = get(data, "manifest", nothing)
            manifest isa String && push!(paths, abspath(directory, manifest))
        end
    end
    # The analyzer's own implementation and resolved dependency graph are inputs.
    for source_root in (@__DIR__, joinpath(tool_root, "scripts"))
        isdir(source_root) || continue
        for (directory, _, files) in walkdir(source_root)
            for name in files
                endswith(name, ".jl") && push!(paths, joinpath(directory, name))
            end
        end
    end
    return Dict(path => file_digest(path) for path in sort!(collect(paths)) if isfile(path))
end

function changed_inputs(before::AbstractDict{String,String}, after::AbstractDict{String,String})
    return sort!([path for path in union(keys(before), keys(after))
                  if get(before, path, nothing) != get(after, path, nothing)])
end
