const HELP = """
    jetsweep — analyze every Julia package, extension, test and script below a directory with JETLS

    Usage: jetsweep [OPTIONS] DIRECTORY

    Options:
      --jobs N            Analyses run in parallel (default: CPU threads, capped by memory)
      --threads N         Threads for package and extension analyses (default: 4)
      --timeout SECONDS   Time limit for each analysis or environment; 0 disables (default: 1800)
      --gpus auto|none|LIST
                          GPUs (indices or UUIDs) assigned round-robin through CUDA_VISIBLE_DEVICES
                          (default: auto)
      --output DIRECTORY  New or empty report directory (default: DIRECTORY/.jetsweep/TIMESTAMP)
      --config FILE       Configuration file (default: DIRECTORY/.JETSweep.toml, if present)
      --exclude GLOB      Skip matching paths; repeatable. A pattern with `/`, or starting with
                          `/` or `./`, matches paths relative to DIRECTORY, others any segment
      --include-ignored   Include files Git ignores
      --tracked-only      Include only files Git tracks
      --offline           Resolve among installed package versions; download nothing
      --plan              Write the inventory and analysis plan without analyzing
      --fail-on LEVEL     Lowest severity that fails: error, warning, info, hint or none
                          (default: hint)
      --version           Show the version
      -h, --help          Show this help

    Exit status: 0 when every analysis completed without diagnostics at or above the
    --fail-on level, 1 when some did, 2 when an analysis is incomplete or failed, discovery
    reported an issue (an unreadable directory or Git repository, or broken project
    metadata), an input changed during the run, or the arguments or configuration are
    invalid, and 130 when interrupted.

    Analysis loads packages and runs their top-level code, macros and generated functions;
    use JETSweep only on code you trust.
    """

function parse_arguments(arguments::Vector{String})
    values = Dict{Symbol,Any}()
    exclude = String[]
    directories = String[]
    flags = Dict("--include-ignored" => :include_ignored, "--tracked-only" => :tracked_only,
                 "--offline" => :instantiate, "--plan" => :plan_only)
    options = ("--jobs", "--threads", "--timeout", "--gpus", "--output", "--config", "--exclude", "--fail-on")
    i = 1
    while i <= length(arguments)
        argument = arguments[i]
        if argument == "--"
            append!(directories, arguments[i+1:end])
            break
        elseif haskey(flags, argument)
            values[flags[argument]] = argument != "--offline"
        elseif startswith(argument, "--")
            name, value = occursin('=', argument) ? split(argument, '='; limit=2) :
                (argument, i < length(arguments) ? arguments[i += 1] : nothing)
            name in options || throw(ArgumentError("unknown option $name"))
            (value === nothing || isempty(value)) && throw(ArgumentError("$name needs a value"))
            value = String(value)
            if name == "--exclude"
                push!(exclude, value)
                i += 1
                continue
            end
            key, parsed = name == "--jobs" ? (:jobs, parse(Int, value)) :
                name == "--threads" ? (:threads, parse(Int, value)) :
                name == "--timeout" ? (:timeout, parse(Float64, value)) :
                name == "--gpus" ? (:gpus, String.(strip.(split(value, ',')))) :
                name == "--output" ? (:output, abspath(value)) :
                name == "--config" ? (:config, abspath(value)) : (:fail_on, Symbol(value))
            haskey(values, key) && throw(ArgumentError("$name given more than once"))
            values[key] = parsed
        elseif startswith(argument, "-")
            throw(ArgumentError("unknown option $argument"))
        else
            push!(directories, argument)
        end
        i += 1
    end
    length(directories) == 1 || throw(ArgumentError("give exactly one directory; see `jetsweep --help`"))
    return only(directories), SweepOptions(; values..., exclude)
end

function (@main)(arguments::Vector{String})::Cint
    any(in(("--help", "-h")), arguments) && (print(stdout, HELP); return 0)
    "--version" in arguments && (println(stdout, "JETSweep ", pkgversion(@__MODULE__)); return 0)
    try
        directory, options = parse_arguments(arguments)
        return sweep(directory; options).exit_code
    catch err
        err isa InterruptException && return 130
        print(stderr, "jetsweep: ")
        showerror(stderr, err)
        println(stderr)
        return 2
    end
end
