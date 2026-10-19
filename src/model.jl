"A Julia project, including unnamed environments and nested packages."
Base.@kwdef struct ProjectRecord
    path::String
    name::String = ""
    uuid::String = ""
    entry::String = ""
    deps::Dict{String,String} = Dict{String,String}()
    weakdeps::Dict{String,String} = Dict{String,String}()
    extensions::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
end

"An inventoried Julia file and the project/package which owns its context."
Base.@kwdef struct SourceRecord
    path::String
    project::String = ""
    owner::String = ""
    kind::Symbol = :script
end

struct Inventory
    root::String
    projects::Vector{ProjectRecord}
    files::Vector{SourceRecord}
    excluded::Vector{String}
    issues::Vector{String}
end

"Explicit additions to an automatically selected analysis context."
Base.@kwdef struct ContextSpec
    project::String = ""
    setup::Vector{String} = String[]
    arguments::Vector{String} = String[]
    variables::Dict{String,String} = Dict{String,String}()
    configuration::String = ""
    test_entry::String = ""
    containing_files::Vector{String} = String[]
end

"One independently isolated package, extension, test, or script analysis."
Base.@kwdef struct AnalysisJob
    id::String
    kind::Symbol
    entry::String
    project::String
    owner::String = ""
    expected_files::Vector{String} = String[]
    extension::String = ""
    triggers::Dict{String,String} = Dict{String,String}()
    context::ContextSpec = ContextSpec()
    issues::Vector{String} = String[]
    blocking_issues::Vector{String} = String[]
end

"An isolated resolved environment; preparation failures are explicit."
Base.@kwdef struct EnvironmentResult
    status::Symbol
    project::String = ""
    load_paths::Vector{String} = String[]
    message::String = ""
    fingerprints::Dict{String,String} = Dict{String,String}()
    tool_project::String = ""
end

"Execution controls shared by the CLI and Julia API."
Base.@kwdef struct SweepOptions
    jobs::Int = min(12, max(1, min(Sys.CPU_THREADS ÷ 4, Int(Sys.total_memory() ÷ (4 * 1024^3)))))
    threads::Int = 2
    timeout::Float64 = 1200.0
    output::String = ""
    config::String = ""
    excludes::Vector{String} = String[]
    gpu_devices::Vector{String} = String[]
    instantiate::Bool = true
    plan_only::Bool = false
    fail_severity::Symbol = :hint
    include_ignored::Bool = false
    include_untracked::Bool = true
end

"A complete sweep record; diagnostics retain the backend's structured payload."
struct SweepResult
    root::String
    output::String
    inventory::Inventory
    jobs::Vector{AnalysisJob}
    results::Vector{Dict{String,Any}}
    started::String
    finished::String
    input_changes::Vector{String}
    exit_code::Int
end
