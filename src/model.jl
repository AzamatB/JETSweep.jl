"""
A Julia project file. A project is a package when it declares a name, a UUID and an entry
file; unnamed projects are plain environments, such as test or script environments.
"""
struct Project
    dir::String
    file::String
    name::String
    uuid::String
    entry::String
    "Declared extensions, each mapping its trigger names to UUIDs."
    extensions::Dict{String,Dict{String,String}}
end

ispackage(project::Project) = !isempty(project.entry)

"A discovered Julia file with its nearest project and owning package directories."
struct Source
    path::String
    "`:package`, `:extension`, `:test` or `:script`, from the file's place in its package."
    kind::Symbol
    project::String
    owner::String
end

"Every Julia project and source below a root, with the paths excluded from discovery."
struct Inventory
    root::String
    projects::Vector{Project}
    sources::Vector{Source}
    excluded::Vector{String}
    issues::Vector{String}
end

"""
The dependency context a unit is loaded in: the selected project, the package that owns
the unit, whether the package's test dependencies apply, and extension triggers. Units
with equal contexts share one prepared environment.
"""
struct Context
    project::String
    owner::String
    test::Bool
    triggers::Dict{String,String}
end

Base.:(==)(a::Context, b::Context) =
    a.project == b.project && a.owner == b.owner && a.test == b.test && a.triggers == b.triggers
Base.hash(context::Context, h::UInt) =
    hash((context.project, context.owner, context.test, sort!(collect(context.triggers))), h)

"Configured additions to a unit's runtime context, from `.JETSweep.toml`."
Base.@kwdef struct Overrides
    setup::Vector{String} = String[]
    args::Vector{String} = String[]
    env::Dict{String,String} = Dict{String,String}()
    jetls_config::String = ""
end

"""
One JETLS analysis, run in its own process: a package, an extension, a test or script
file, or a package source file that its package never includes (`:orphan`).
"""
struct Unit
    id::String
    kind::Symbol
    entry::String
    context::Context
    "Files the analysis must cover: the entry and everything it statically includes."
    expected::Vector{String}
    "Test driver whose declarations precede a test file it includes dynamically, or \"\"."
    driver::String
    extension::String
    overrides::Overrides
    "Static planning observations, such as includes that cannot be resolved."
    notes::Vector{String}
end

"A diagnostic reported by JETLS for an original source file."
struct Finding
    file::String
    line::Int
    column::Int
    end_line::Int
    end_column::Int
    severity::Int
    code::String
    message::String
end

const SEVERITIES = (:error, :warning, :info, :hint)

"""
The outcome of one unit. `status` is `:clean` or `:findings` only for a complete
analysis; otherwise it is `:incomplete`, `:timeout`, `:failed` or `:unavailable`, and
`reasons` explains why. `notes` record what does not affect completeness, such as
package files that loading left out, which are then analyzed as `:orphan` units.
"""
struct UnitResult
    unit::String
    status::Symbol
    findings::Vector{Finding}
    analyzed::Vector{String}
    reasons::Vector{String}
    notes::Vector{String}
    seconds::Float64
    log::String
end

complete(result::UnitResult) = result.status in (:clean, :findings)

"Controls shared by the command line and the Julia API."
Base.@kwdef struct SweepOptions
    jobs::Int = default_jobs()
    threads::Int = 4
    timeout::Float64 = 1800.0
    output::String = ""
    config::String = ""
    exclude::Vector{String} = String[]
    gpus::Vector{String} = ["auto"]
    instantiate::Bool = true
    plan_only::Bool = false
    fail_on::Symbol = :hint
    include_ignored::Bool = false
    tracked_only::Bool = false
end

"Parallel workers that fit the machine: one per core, at most one per 3 GiB of memory."
default_jobs() = max(1, min(Sys.CPU_THREADS, Int(Sys.total_memory() ÷ (3 * 1024^3))))

"A finished sweep: its inventory, units, their results, and the derived exit code."
struct SweepResult
    root::String
    output::String
    inventory::Inventory
    units::Vector{Unit}
    results::Vector{UnitResult}
    changed::Vector{String}
    seconds::Float64
    exit_code::Int
end
