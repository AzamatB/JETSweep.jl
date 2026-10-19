_display(path::String, root::String) = _within(path, root) ? relpath(path, root) : path

function write_inventory(file::String, inventory::Inventory)
    _write_toml(file, Dict(
        "root" => inventory.root,
        "projects" => [Dict("dir" => p.dir, "file" => p.file, "name" => p.name, "uuid" => p.uuid,
                            "entry" => p.entry, "extensions" => p.extensions) for p in inventory.projects],
        "sources" => [Dict("path" => s.path, "kind" => String(s.kind), "project" => s.project, "owner" => s.owner)
                      for s in inventory.sources],
        "excluded" => inventory.excluded, "issues" => inventory.issues))
end

function _unit_dict(unit::Unit)
    return Dict("id" => unit.id, "kind" => String(unit.kind), "entry" => unit.entry,
        "expected" => unit.expected, "driver" => unit.driver, "extension" => unit.extension,
        "context" => Dict("project" => unit.context.project, "owner" => unit.context.owner,
                          "test" => unit.context.test, "triggers" => unit.context.triggers),
        "setup" => unit.overrides.setup, "args" => unit.overrides.args, "env" => unit.overrides.env,
        "jetls_config" => unit.overrides.jetls_config, "notes" => unit.notes)
end

write_plan(file::String, units::Vector{Unit}, root::String) =
    _write_toml(file, Dict("root" => root, "units" => _unit_dict.(units)))

function report_progress(io::IO, unit::Unit, result::UnitResult, done::Int, total::Int, root::String)
    width = ndigits(total)
    detail = if !complete(result)
        isempty(result.reasons) ? "" : first(split(first(result.reasons), '\n'))
    else
        isempty(result.findings) ? "" : "$(length(result.findings)) diagnostics"
    end
    println(io, "[", lpad(done, width), "/", total, "] ", rpad(String(result.status), 11),
            lpad(string(round(result.seconds; digits=1), "s"), 7), "  ", _display(unit.entry, root),
            isempty(unit.extension) ? "" : " ($(unit.extension))", isempty(detail) ? "" : " — $detail")
    flush(io)
end

"Findings deduplicated across units, which can analyze the same file."
function unique_findings(results::Vector{UnitResult})
    findings = unique!(reduce(vcat, (result.findings for result in results); init=Finding[]))
    return sort!(findings; by=f -> (f.file, f.line, f.column, f.code, f.message))
end

function exit_code(inventory::Inventory, results::Vector{UnitResult}, changed::Vector{String}, fail_on::Symbol)
    (!isempty(inventory.issues) || !isempty(changed) || !all(complete, results)) && return 2
    threshold = fail_on === :none ? 0 : findfirst(==(fail_on), SEVERITIES)
    return any(f -> f.severity <= threshold, unique_findings(results)) ? 1 : 0
end

const _SEVERITY_NAMES = ("error", "warning", "info", "hint")

function write_report(result::SweepResult; io::IO=stderr)
    root = result.root
    findings = unique_findings(result.results)
    statuses = Dict{String,Int}()
    foreach(r -> statuses[String(r.status)] = get(statuses, String(r.status), 0) + 1, result.results)
    severities = [count(f -> f.severity == s, findings) for s in 1:4]
    codes = Dict{String,Int}()
    foreach(f -> codes[f.code] = get(codes, f.code, 0) + 1, findings)
    analyzed = Set(file for r in result.results if complete(r) for file in r.analyzed)
    unanalyzed = sort!([s.path for s in result.inventory.sources if !(realpath(s.path) in analyzed)])
    byid = Dict(unit.id => unit for unit in result.units)
    _write_toml(joinpath(result.output, "report.toml"), Dict(
        "root" => root, "julia" => string(VERSION), "jetsweep" => string(pkgversion(@__MODULE__)),
        "seconds" => result.seconds, "exit_code" => result.exit_code,
        "files" => length(result.inventory.sources), "units" => length(result.units), "statuses" => statuses,
        "discovery_issues" => result.inventory.issues, "changed_during_run" => result.changed,
        "unanalyzed" => unanalyzed,
        "results" => [Dict("unit" => r.unit, "kind" => String(byid[r.unit].kind), "entry" => byid[r.unit].entry,
                           "status" => String(r.status), "seconds" => r.seconds, "findings" => length(r.findings),
                           "reasons" => r.reasons, "notes" => r.notes, "log" => r.log) for r in result.results],
        "findings" => [Dict("file" => f.file, "line" => f.line, "column" => f.column, "end_line" => f.end_line,
                            "end_column" => f.end_column, "severity" => _SEVERITY_NAMES[f.severity],
                            "code" => f.code, "message" => f.message) for f in findings]))
    open(joinpath(result.output, "summary.txt"), "w") do summary
        for finding in findings
            println(summary, _display(finding.file, root), ':', finding.line, ':', finding.column, ": ",
                    _SEVERITY_NAMES[finding.severity], " [", finding.code, "]")
            for line in eachsplit(finding.message, '\n')
                println(summary, "    ", line)
            end
        end
        isempty(findings) || println(summary)
        _summarize(summary, result, findings, statuses, severities, codes, unanalyzed, byid)
    end
    _summarize(io, result, findings, statuses, severities, codes, unanalyzed, byid)
    return nothing
end

function _summarize(io::IO, result::SweepResult, findings, statuses, severities, codes, unanalyzed, byid)
    root = result.root
    println(io)
    println(io, "JETSweep analyzed $(length(result.units)) units in $(round(result.seconds; digits=1)) s: ",
            join(("$n $status" for (status, n) in sort!(collect(statuses))), ", "))
    println(io, length(findings), " unique diagnostics",
            isempty(findings) ? "" : ": " * join(("$n $(_SEVERITY_NAMES[s])" for (s, n) in pairs(severities) if n > 0), ", "))
    for (code, n) in first(sort!(collect(codes); by=last, rev=true), 10)
        println(io, "  ", lpad(n, 6), "  ", code)
    end
    for issue in result.inventory.issues
        println(io, "Discovery issue: ", issue)
    end
    for file in result.changed
        println(io, "Changed during the run: ", _display(file, root))
    end
    for r in result.results
        complete(r) && continue
        unit = byid[r.unit]
        println(io, "Incomplete ($(r.status)): ", _display(unit.entry, root), isempty(unit.extension) ? "" : " ($(unit.extension))")
        for reason in first(r.reasons, 3)
            println(io, "    ", first(split(reason, '\n')))
        end
        isempty(r.log) || println(io, "    log: ", r.log)
    end
    isempty(unanalyzed) || println(io, length(unanalyzed), " files were not covered by a complete analysis")
    println(io, "Report: ", joinpath(result.output, "report.toml"))
    println(io, "Summary: ", joinpath(result.output, "summary.txt"))
    return nothing
end
