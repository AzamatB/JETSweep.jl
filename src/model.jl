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

"Every Julia project and source below a root, the projects above it, and the paths excluded from discovery."
struct Inventory
    root::String
    projects::Vector{Project}
    sources::Vector{Source}
    """
    Packages the sweep leaves out, which its code may still load, in two tiers: those of the
    full sweep, of the configuration's directory, that `--exclude` or a narrower root leaves
    out, then those the configuration excludes.
    """
    available::Vector{Vector{Project}}
    excluded::Vector{String}
    issues::Vector{String}
end

"""
The dependency context a unit is loaded in: the selected project, the package that owns
the unit, whether the package's test dependencies apply, extension triggers, and packages
its code imports without its projects declaring them. Units with equal contexts share one
prepared environment.
"""
struct Context
    project::String
    owner::String
    test::Bool
    triggers::Dict{String,String}
    "Undeclared imports: the directory of each package in the workspace, `\"\"` for registered ones."
    imports::Dict{String,String}
end
Context(project, owner, test, triggers) = Context(project, owner, test, triggers, Dict{String,String}())

Base.:(==)(a::Context, b::Context) = a.project == b.project && a.owner == b.owner && a.test == b.test &&
    a.triggers == b.triggers && a.imports == b.imports
Base.hash(context::Context, h::UInt) =
    hash((context.project, context.owner, context.test, context.triggers, context.imports), h)

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
    jobs::Int = Sys.CPU_THREADS
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

"The memory a worker is planned with: about what an analysis of a large package takes."
const WORKER_MEMORY = 3 * 1024^3

"""
    worker_cap(threads=Sys.CPU_THREADS, free=Sys.free_memory()) -> Int

The `jobs` slots that fit the machine: one per CPU thread and one per `WORKER_MEMORY` of free
memory, at least one. Every sweep of a process takes its slots from these: the process uses at
most `worker_cap()` at once, as it was when none was in use, whatever `jobs` asks.
"""
worker_cap(threads::Integer=Sys.CPU_THREADS, free::Integer=Sys.free_memory()) =
    max(1, min(Int(threads), Int(free ÷ WORKER_MEMORY)))

"A finished sweep: its inventory, units, their results, and the derived exit code."
struct SweepResult
    root::String
    output::String
    inventory::Inventory
    units::Vector{Unit}
    "Planning observations about the sweep as a whole, such as contexts that select no unit of it."
    notes::Vector{String}
    results::Vector{UnitResult}
    changed::Vector{String}
    seconds::Float64
    exit_code::Int
end
