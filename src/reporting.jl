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
    detail = if !complete(result)
        isempty(result.reasons) ? "" : _relative(first(split(first(result.reasons), '\n')), root)
    else
        isempty(result.findings) ? "" : "$(length(result.findings)) diagnostics"
    end
    println(io, "[", done, "/", total, "] ", rpad(String(result.status), 11),
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

_severity(level::Integer) = String(SEVERITIES[level])

"Text with paths below `root` shown relative to it."
_relative(text::AbstractString, root::String) = replace(text, root * "/" => "")

function write_report(result::SweepResult; io::IO=stderr)
    root = result.root
    findings = unique_findings(result.results)
    statuses = Dict{String,Int}()
    foreach(r -> statuses[String(r.status)] = get(statuses, String(r.status), 0) + 1, result.results)
    severities = [count(f -> f.severity == level, findings) for level in eachindex(SEVERITIES)]
    codes = Dict{String,Int}()
    foreach(f -> codes[f.code] = get(codes, f.code, 0) + 1, findings)
    analyzed = Set(file for r in result.results if complete(r) for file in r.analyzed)
    unanalyzed = sort!([s.path for s in result.inventory.sources if !(s.path in analyzed)])
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
                            "end_column" => f.end_column, "severity" => _severity(f.severity),
                            "code" => f.code, "message" => f.message) for f in findings]))
    open(joinpath(result.output, "summary.txt"), "w") do summary
        for finding in findings
            println(summary, _display(finding.file, root), ':', finding.line, ':', finding.column, ": ",
                    _severity(finding.severity), " [", finding.code, "]")
            for line in eachsplit(finding.message, '\n')
                println(summary, "    ", line)
            end
        end
        isempty(findings) || println(summary)
        _summarize(summary, result, findings, statuses, severities, codes, unanalyzed, byid; detailed=true)
    end
    _summarize(io, result, findings, statuses, severities, codes, unanalyzed, byid; detailed=false)
    return nothing
end

"Why a unit did not complete, without the locations that differ from unit to unit."
function _cause(result::UnitResult)
    result.status === :timeout && return "time limit exceeded"
    reason = isempty(result.reasons) ? "" : first(split(first(result.reasons), '\n'))
    stop = match(r"^analysis stopped at .*?:\d+ \[([^\]]+)\]:", reason)
    stop === nothing || return "analysis stopped [$(stop[1])]"
    return length(reason) > 160 ? first(reason, 159) * "…" : reason
end

function _summarize(io::IO, result::SweepResult, findings, statuses, severities, codes, unanalyzed, byid; detailed::Bool)
    root = result.root
    println(io)
    println(io, "JETSweep analyzed $(length(result.units)) units in $(round(result.seconds; digits=1)) s: ",
            join(("$n $status" for (status, n) in sort!(collect(statuses))), ", "))
    println(io, length(findings), " unique diagnostics",
            isempty(findings) ? "" : ": " * join(("$n $(_severity(level))" for (level, n) in pairs(severities) if n > 0), ", "))
    for (code, n) in first(sort!(collect(codes); by=last, rev=true), 10)
        println(io, "  ", lpad(n, 6), "  ", code)
    end
    for issue in result.inventory.issues
        println(io, "Discovery issue: ", _relative(issue, root))
    end
    for file in result.changed
        println(io, "Changed during the run: ", _display(file, root))
    end
    name(unit) = _display(unit.entry, root) * (isempty(unit.extension) ? "" : " ($(unit.extension))")
    incomplete = filter(!complete, result.results)
    if detailed
        for r in incomplete
            println(io, rpad(String(r.status), 11), " ", name(byid[r.unit]))
            foreach(reason -> println(io, "    ", _relative(first(split(reason, '\n')), root)), r.reasons)
            isempty(r.log) || println(io, "    log: ", r.log)
        end
        isempty(unanalyzed) || println(io, "Files no complete analysis covered:")
        foreach(file -> println(io, "    ", _display(file, root)), unanalyzed)
    else
        groups = Dict{Tuple{Symbol,String},Vector{UnitResult}}()
        foreach(r -> push!(get!(groups, (r.status, _relative(_cause(r), root)), UnitResult[]), r), incomplete)
        for ((status, cause), members) in sort!(collect(groups); by=group -> -length(last(group)))
            println(io, lpad(length(members), 5), "  ", rpad(String(status), 11), " ", cause)
            examples = join((name(byid[r.unit]) for r in first(members, 3)), ", ")
            println(io, "         ", examples, length(members) > 3 ? ", and $(length(members) - 3) more" : "")
        end
        isempty(unanalyzed) || println(io, length(unanalyzed), length(unanalyzed) == 1 ? " file" : " files",
                                       " not covered by a complete analysis; see the summary")
    end
    println(io, "Report: ", joinpath(result.output, "report.toml"))
    println(io, "Summary: ", joinpath(result.output, "summary.txt"))
    return nothing
end
