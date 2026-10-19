using TOML, LibGit2

function discovery_file(root, relative, contents="nothing\n")
    path = joinpath(root, relative)
    mkpath(dirname(path))
    write(path, contents)
    return path
end

function discovery_project(root, relative; name="", uuid="", entry="", extra=Dict{String,Any}())
    directory = joinpath(root, relative)
    mkpath(directory)
    data = Dict{String,Any}(extra)
    isempty(name) || (data["name"] = name)
    isempty(uuid) || (data["uuid"] = uuid)
    isempty(entry) || (data["entryfile"] = entry)
    open(joinpath(directory, "Project.toml"), "w") do io
        TOML.print(io, data; sorted=true)
    end
    if !isempty(name) && !isempty(uuid)
        discovery_file(directory, isempty(entry) ? joinpath("src", "$name.jl") : entry, "module $name\nend\n")
    end
    return directory
end

function discovery_tree(root)
    discovery_project(root, ".")
    first = discovery_project(root, "first package"; name="Repeated", uuid="e465d4d7-f5b7-4ccf-bc8a-9f021e55417a",
        extra=Dict("weakdeps" => Dict("Dates" => "ade2ca70-3891-5945-98fb-dc099432e06a"),
                   "extensions" => Dict("RepeatedDatesExt" => ["Dates"])))
    discovery_file(first, "src/disconnected.jl", "disconnected(x) = x + 1\n")
    discovery_file(first, "ext/RepeatedDatesExt/RepeatedDatesExt.jl",
        "module RepeatedDatesExt\ninclude(\"helper.jl\")\nend\n")
    discovery_file(first, "ext/RepeatedDatesExt/helper.jl", "extension_helper(x) = x\n")
    discovery_file(first, ".pkg/select_artifacts.jl")
    discovery_file(first, "test/runtests.jl", "using Test\nconst count = 3\ninclude(\"groups/basic.jl\")\n")
    discovery_file(first, "test/groups/basic.jl", "const local_count = count\ninclude(\"helper.jl\")\n")
    discovery_file(first, "test/groups/helper.jl", "helper(x) = x + local_count\n")
    discovery_project(first, "test")
    nested = discovery_project(first, "src/Nested"; name="Nested", uuid="9d9af008-05b8-4cb6-8252-4ba3a37ae9ef")
    second = discovery_project(root, "nested folder/second package"; name="Repeated", uuid="e465d4d7-f5b7-4ccf-bc8a-9f021e55417b")
    alternate = discovery_project(root, "alternate"; name="Alternate", uuid="0a7d5d82-8fb7-4949-9ee2-680c786f357c", entry="lib/start.jl")
    discovery_file(root, "broken/Project.toml", "[deps\n")
    discovery_file(root, "broken/script.jl")
    discovery_file(root, "loose scripts/main.jl")
    discovery_file(root, "node_modules/generated.jl")
    discovery_file(root, ".jetsweep/worker.jl")
    discovery_file(root, "audit output/generated.jl")
    discovery_file(root, ".hidden/retained.jl")
    symlink(root, joinpath(root, "loop"))
    return (; first, second, nested, alternate)
end
