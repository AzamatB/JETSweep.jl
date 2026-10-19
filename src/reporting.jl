function _file_coverage(report::SweepResult)
    covered = Set{String}()
    attempted = Set{String}()
    for result in report.results
        union!(attempted, _canonical_file.(get(result, "expected_files", String[])))
        get(result, "full_analysis_complete", false) &&
            union!(covered, _canonical_file.(get(result, "analyzed_files", String[])))
    end
    return [Dict("path" => file.path, "kind" => String(file.kind),
        "status" => _canonical_file(file.path) in covered ? "covered" :
                    _canonical_file(file.path) in attempted ? "incomplete" : "not_analyzed")
            for file in report.inventory.files]
end

function write_report(report::SweepResult; io::IO=stderr)
    statuses = Dict{String,Int}()
    diagnostics = Dict{Tuple{String,Int,Int,String,Int,String},Dict{String,Any}}()
    for result in report.results
        status = get(result, "status", "analysis_incomplete")
        statuses[status] = get(statuses, status, 0) + 1
        for diagnostic in get(result, "diagnostics", [])
            key = (String(get(diagnostic, "file", "")), Int(get(diagnostic, "line", 0)),
                Int(get(diagnostic, "column", 0)), String(get(diagnostic, "code", "")),
                Int(get(diagnostic, "severity", 1)), String(get(diagnostic, "message", "")))
            diagnostics[key] = diagnostic
        end
    end
    unique_diagnostics = [diagnostics[key] for key in sort!(collect(keys(diagnostics)))]
    coverage = _file_coverage(report)
    record = Dict{String,Any}(
        "schema_version" => 1, "root" => report.root, "output" => report.output,
        "started" => report.started, "finished" => report.finished,
        "exit_code" => report.exit_code,
        "status" => report.exit_code == 2 ? "incomplete" :
                    isempty(unique_diagnostics) ? "clean" : "findings",
        "julia_version" => string(VERSION), "jetsweep_version" => string(pkgversion(@__MODULE__)),
        "files" => length(report.inventory.files),
        "packages" => count(project -> !isempty(project.entry), report.inventory.projects),
        "jobs" => length(report.jobs), "job_statuses" => statuses,
        "discovery_issues" => report.inventory.issues,
        "excluded" => report.inventory.excluded, "input_changes" => report.input_changes,
        "coverage" => coverage, "diagnostics" => unique_diagnostics, "results" => report.results,
        "scope" => "JETLS full and live diagnostics in the recorded environments. Source coverage does not prove inference for every possible concrete method specialization. Tests and scripts are analyzed, not a substitute for running their functional or numerical suites.")
    write_toml(joinpath(report.output, "report.toml"), record)
    open(joinpath(report.output, "summary.txt"), "w") do summary
        println(summary, "JETSweep $(record["status"]): $(record["files"]) files, $(record["packages"]) packages, $(record["jobs"]) jobs")
        println(summary, "Root: ", report.root)
        println(summary, "Exit code: ", report.exit_code)
        for status in sort!(collect(keys(statuses)))
            println(summary, "  $status: $(statuses[status])")
        end
        println(summary, "Unique diagnostics: ", length(unique_diagnostics))
        println(summary, "Excluded paths: ", length(report.inventory.excluded))
        for issue in report.inventory.issues
            println(summary, "Discovery: ", issue)
        end
        for path in report.input_changes
            println(summary, "Changed input: ", path)
        end
        for result in report.results
            get(result, "full_analysis_complete", false) && continue
            println(summary, '\n', get(result, "entry", "Unknown entry"), " [",
                get(result, "status", "analysis_incomplete"), "]")
            error = string(get(result, "error", ""))
            isempty(error) || println(summary, "  ", first(split(error, '\n')))
            for key in ("protocol_errors", "blocking_issues", "internal_errors")
                for reason in get(result, key, String[])
                    println(summary, "  ", reason)
                end
            end
            for file in get(result, "missing_files", String[])
                println(summary, "  Missing source coverage: ", file)
            end
            log = get(result, "log", "")
            isempty(log) || println(summary, "  Log: ", log)
        end
        println(summary, '\n', record["scope"])
        for diagnostic in unique_diagnostics
            println(summary, '\n', get(diagnostic, "file", ""), ':', get(diagnostic, "line", 0),
                ':', get(diagnostic, "column", 0), " [", get(diagnostic, "code", ""), "]")
            println(summary, get(diagnostic, "message", ""))
        end
    end
    println(io, "$(length(unique_diagnostics)) unique diagnostics; report: $(joinpath(report.output, "report.toml"))")
    return record
end
