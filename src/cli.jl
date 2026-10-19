const CLI_HELP = """
JETSweep — recursive Julia workspace analysis with JETLS

Usage: jetsweep [OPTIONS] DIRECTORY

  --jobs N                  Concurrent isolated workers (default: CPU/RAM-based, up to 12)
  --threads N               Julia threads per worker (default: 2)
  --gpus auto|none|LIST      GPU indices or UUIDs assigned round-robin (default: auto)
  --timeout SECONDS         Time limit per environment or analysis job; 0 disables (default: 1200)
  --output DIRECTORY        New or empty report directory (default: DIRECTORY/.jetsweep/RUN)
  --config FILE             Context overrides (default: DIRECTORY/.JETSweep.toml if present)
  --exclude GLOB            Exclude a root-relative path pattern; repeatable
  --include-ignored         Include Git-ignored files
  --tracked-only            Exclude untracked files inside Git repositories
  --no-instantiate          Use locally available dependencies only
  --plan                    Discover files and write a job plan without starting analysis
  --fail-on LEVEL           error, warning, info, hint, or none (default: hint)
  --help                    Show this help
  --version                 Show the JETSweep version

Packages, nested packages, tests, extensions and standalone Julia scripts are
included. Dependencies resolve in isolated metadata environments. Reports retain
all diagnostic severities and explicitly record unavailable or incomplete contexts.

Exit codes: 0 completed below the selected severity; 1 findings; 2 incomplete/error;
130 interrupted. Analysis can execute Julia imports, macros and generated code;
use it on workspaces you trust. It does not run the functional test suites.
"""

function _parse_cli(arguments::Vector{String})
    values = Dict{Symbol,Any}()
    excludes = String[]
    roots = String[]
    index = 1
    options_done = false
    while index <= length(arguments)
        argument = arguments[index]
        if argument == "--" && !options_done
            options_done = true
        elseif !options_done && startswith(argument, "--")
            option, inline = if occursin('=', argument)
                parts = split(argument, '='; limit=2)
                String(parts[1]), String(parts[2])
            else
                argument, nothing
            end
            booleans = Dict("--plan" => :plan_only, "--include-ignored" => :include_ignored,
                            "--tracked-only" => :include_untracked, "--no-instantiate" => :instantiate)
            if haskey(booleans, option)
                inline === nothing || throw(ArgumentError("$option takes no value"))
                values[booleans[option]] = option in ("--plan", "--include-ignored")
            else
                option in ("--jobs", "--threads", "--gpus", "--timeout", "--output", "--config", "--exclude", "--fail-on") ||
                    throw(ArgumentError("unknown option: $option"))
                if inline === nothing
                    index += 1
                    index <= length(arguments) || throw(ArgumentError("$option requires a value"))
                    inline = arguments[index]
                end
                isempty(inline) && throw(ArgumentError("$option requires a nonempty value"))
                if option == "--exclude"
                    push!(excludes, inline)
                else
                    key, value = if option == "--jobs"
                        :jobs, parse(Int, inline)
                    elseif option == "--threads"
                        :threads, parse(Int, inline)
                    elseif option == "--timeout"
                        :timeout, parse(Float64, inline)
                    elseif option == "--gpus"
                        :gpu_devices, String.(strip.(split(inline, ',')))
                    elseif option == "--fail-on"
                        :fail_severity, Symbol(inline)
                    elseif option == "--output"
                        :output, abspath(inline)
                    else
                        :config, abspath(inline)
                    end
                    haskey(values, key) && throw(ArgumentError("$option was specified more than once"))
                    values[key] = value
                end
            end
        elseif !options_done && startswith(argument, '-')
            throw(ArgumentError("unknown option: $argument"))
        else
            push!(roots, argument)
        end
        index += 1
    end
    length(roots) == 1 || throw(ArgumentError("supply exactly one directory; use --help for usage"))
    options = SweepOptions(; values..., excludes)
    isfinite(options.timeout) || throw(ArgumentError("timeout must be finite"))
    return only(roots), options
end

function (@main)(arguments::Vector{String})::Cint
    if arguments == ["--help"] || arguments == ["-h"]
        print(stdout, CLI_HELP)
        return 0
    elseif arguments == ["--version"]
        println("JETSweep ", pkgversion(@__MODULE__))
        return 0
    end
    try
        root, options = _parse_cli(arguments)
        return Cint(sweep(root; options).exit_code)
    catch error
        error isa InterruptException && return 130
        print(stderr, "JETSweep: ")
        showerror(stderr, error)
        println(stderr)
        return 2
    end
end
