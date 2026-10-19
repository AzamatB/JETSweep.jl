# JETSweep.jl

Analyze every Julia package, extension, test and script below a directory with
[JETLS](https://github.com/aviatesk/JETLS.jl), in one command:

```sh
jetsweep /path/to/workspace
```

JETSweep finds the packages, nested packages, test suites, extensions and standalone scripts
of a workspace, prepares their dependency environments, and runs a full JETLS analysis of each
in its own process, in parallel. It reports every diagnostic of the original source files —
inference failures, method errors, undefined names, structs with abstract fields, unused
code and so on — and says plainly which analyses could not complete, and why.

## Install

JETSweep requires Julia 1.13. It uses JETLS 2026.10.14, pinned to that release's commit
because the analysis entry points it drives are internal to JETLS.

```julia
using Pkg
Pkg.Apps.add(url="https://github.com/AzamatB/JETSweep.jl")
```

This installs the `jetsweep` command into `~/.julia/bin`; add that directory to `PATH`.
From a checkout, `julia --project -m JETSweep DIRECTORY` runs the same command.

## Usage

```sh
jetsweep ~/Projects/Workspace                   # analyze everything, report to .jetsweep/
jetsweep --plan ~/Projects/Workspace            # write the analysis plan only
jetsweep --jobs 24 --fail-on warning DIRECTORY  # 24 analyses at a time; fail only on warnings and errors
jetsweep --exclude vendor --exclude '**/generated/*.jl' DIRECTORY
```

| Option | Meaning |
| --- | --- |
| `--jobs N` | Analyses run in parallel. Default: the CPU threads, at most one per 3 GiB of memory. |
| `--threads N` | Threads for package and extension analyses, whose signature analysis is parallel (default 4). Other analyses run single-threaded. |
| `--timeout SECONDS` | Time limit per analysis or environment, 0 for none (default 1800). |
| `--gpus auto\|none\|LIST` | GPUs assigned round-robin through `CUDA_VISIBLE_DEVICES` (default `auto`: the visible devices). |
| `--output DIRECTORY` | Report directory, new or empty (default `DIRECTORY/.jetsweep/TIMESTAMP`). |
| `--config FILE` | Configuration file (default `DIRECTORY/.JETSweep.toml`, if present). |
| `--exclude GLOB` | Skip matching paths; repeatable. A pattern with `/` inside, or starting with `/` or `./`, matches the path relative to `DIRECTORY`; any other pattern matches a path segment. |
| `--include-ignored`, `--tracked-only` | Include files Git ignores; include only files Git tracks. |
| `--offline` | Resolve environments among the package versions already installed, and download nothing. |
| `--plan` | Write the inventory and the analysis plan without analyzing. |
| `--fail-on LEVEL` | Lowest severity that fails the run: `error`, `warning`, `info`, `hint` (default) or `none`. |
| `--version`, `-h`, `--help` | Show the version, or the help. |

## What is analyzed

Discovery walks the directory with each Git repository's own ignore rules (nested
repositories included); outside Git everything is included. Hidden directories are skipped
unless Git tracks files inside them, so editor and tool state stays out while, for example,
a JLL package's tracked `.pkg` scripts stay in. Symlinks are not followed: inside the root
they only alias what discovery reaches anyway, or what it excludes. The files are then
grouped into analysis units, each covering its entry file and the files it includes:

| Unit | Entry | Analysis |
| --- | --- | --- |
| Package | `src/Name.jl`, or the project's `entryfile` | The package is loaded and every method signature is analyzed (JETLS's Revise-based package analysis); its structs are checked for abstract fields. |
| Extension | `ext/Name.jl` or `ext/Name/Name.jl` | Loaded with its parent package and trigger packages, then analyzed like a package. |
| Test driver | `test/runtests.jl` | Script analysis in the package's test environment. A nested `runtests.jl` its driver includes statically is part of its unit; one included at run time is a driver run by the one above it. |
| Test file | any other test file | Script analysis after a prelude from the drivers that run it, for test files a driver includes at run time. |
| Script | any other file | Script analysis in its nearest environment; a package's own scripts use its test environment. |
| Orphan source | package or extension source that loading leaves out | Script analysis with the bindings and imports of the package's or extension's module in scope, as if it included the file. |

Test drivers commonly choose their test files at run time, as in
`for file in (isempty(ARGS) ? ALL_TESTS : ARGS) include(file) end`, which static analysis cannot
follow. Each such test file therefore gets its own unit, analyzed after a prelude of what the
drivers set up before including it: imports, definitions, and the constants and modules the
test file refers to, copied with their original source text; selection logic the test file
does not depend on is left out. The drivers' own analyses evaluate the selection and skip
including the files analyzed separately.

Script analysis evaluates definitions, imports and includes but not assignments, so a
definition or `include` that needs an assigned value stops JETLS
(`toplevel/missing-concretization`), and other code sees assigned values only as types.
JETSweep therefore lets JETLS evaluate the top-level statements of the files a unit loads
that cannot have side effects: assignments of literals, paths and pure functions of names
already bound, such as `const ROOT = normpath(joinpath(@__DIR__, ".."))`, and blocks and
conditionals made only of these, definitions and imports, such as
`if !@isdefined(Alias) const Alias = Package end`.

Values that depend on how and where the program runs (`ARGS`, `ENV`, files read) are
evaluated only where JETLS needs them: in the arguments of `include` and `eval` calls, in
definition signatures, and in conditions that define closures or choose imports. And since
JETLS always evaluates `include` and `eval` calls, whatever their arguments need is evaluated,
side effects or not, as a test driver's selection of its files is. A value that code left
unevaluated may change, as `push!` or an indexed assignment does, is not evaluated from there
on, and neither is a name the file rebinds, even one Base defines. JETLS matches these
statements as patterns, in which names such as `x_` and `@__DIR__` are wildcards, so a
statement whose pattern would also match another statement of its file is not evaluated.

JETSweep extends one JETLS rule. To define a closure in a branch, JETLS evaluates the
branch's condition, and with it everything the condition depends on: in a test set, the
test itself. So JETLS analyzes a `@test` expression that defines an anonymous function in a
branch, as in `@test isnothing(x) || all(y -> y > 0, x)`, inside a closure of its own.
JETSweep treats generators and comprehensions alike, as in
`@test r.ok && [a.b for a in r.items] == [1]`, which would otherwise run the whole test set in
JETLS's interpreter.

Files a finished analysis does not reach, such as package files loading leaves out or files
after an analysis stop, get follow-up units of their own, in the same context: a package's
or extension's missed files are analyzed in its module, each group under the file that
includes the rest. A missed file that a submodule includes cannot be analyzed in its scope
by itself and stays uncovered, as do a JLL package's wrappers for other platforms.
Files of analyses that time out, fail or have no environment are not analyzed elsewhere; the
summary lists every file no complete analysis covered.

Every unit runs in a fresh worker process. Units with the same dependency context share one
prepared environment: a scratch project in the report directory that combines the
package's dependencies, its test dependencies (test target or `test/Project.toml`) or
extension triggers, `[sources]`, workspaces, compat bounds and effective preferences, with
the analyzer resolved alongside, so that packages both use, such as Revise, have one version.
Existing manifests seed the resolution, keeping locked versions where they are consistent;
when they are not, the environment is re-resolved and the units' notes say what changed.
Scripts and tests that import packages their projects do not declare, because they run
with another project active or rely on their workspace, get those packages added: packages
of the workspace from their directories, others from the registry. The units' notes name
them, and if they cannot be added, the environment is prepared without them. With
`--offline`, resolution considers installed versions only. Each environment is then
precompiled once for all its units; packages that fail to precompile, or that a timeout
leaves without package images, load from source. Original projects, manifests, preferences
and sources are never written, and package build scripts never run.

The scheduler prepares environments first, then starts the longest analyses, as measured by
the latest report in `DIRECTORY/.jetsweep` if the same JETSweep version wrote it, or
estimated from source size, and assigns GPUs round-robin. Each analysis takes one of the
`--jobs` slots: package analyses run on `--threads` threads, but use little more than one core
on average. Workers run with Julia's default code generation flags, so they share the
package images of ordinary sessions. On Linux without a display, they share a virtual one
when Xvfb is installed, so packages that open windows when they load, such as GLMakie, load. Analysis is static, but it loads packages and runs their
initialization, macros and generated functions, and the code JETLS evaluates to analyze
scripts: use JETSweep only on code you trust.

## Configuration

`.JETLSConfig.toml` files are respected: each unit uses the nearest one at or above its
entry, with paths relative to its directory, as in the editor, so severity overrides and
concretization patterns apply. JETSweep prepares environments itself, so it sets
`full_analysis.auto_instantiate = "never"`, and it keeps diagnostics enabled for all files.

An optional `.JETSweep.toml` at the root adds exclusions and context for units that need it,
such as scripts that expect arguments or a different environment. `exclude` patterns follow
the `--exclude` rules. Each `match` is a glob that a unit's entry path, relative to the root,
must match whole, and must select at least one planned unit; `project`, `setup` and
`jetls_config` are paths relative to the configuration file. When several tables match a
unit, each key a later table sets overrides earlier ones, except `env`, whose variables
merge. Follow-up units inherit the context and settings of the unit they follow, without
`setup` for orphans.

```toml
exclude = ["vendor", "**/generated/*.jl"]

[[context]]
match = "tools/check.jl"        # units whose entry matches
project = "tools"               # environment to analyze in
setup = ["tools/setup.jl"]      # files included before the entry
args = ["--fast"]               # ARGS during analysis
env = { MODE = "analysis" }     # environment variables during analysis
jetls_config = "tools/.JETLSConfig.toml"
```

## Reports

The report directory contains `report.toml` (every unit's status, reasons, notes and
timing, and the deduplicated diagnostics), `summary.txt` (the diagnostics as
`file:line:column` with messages, every incomplete unit with its reasons and log, and the
files no complete analysis covered), the inventory and plan, and each unit's and
environment's request, result and log. The terminal summary groups incomplete units by cause.

| Exit | Meaning |
| --- | --- |
| 0 | Every analysis completed, with no diagnostic at or above `--fail-on`. |
| 1 | Every analysis completed, with diagnostics at or above `--fail-on`. |
| 2 | An analysis was incomplete, timed out or failed; discovery reported an issue (an unreadable directory or Git repository, or broken project metadata); an input changed during the run; or the arguments or configuration are invalid. With `--plan`, only discovery issues count. |
| 130 | Interrupted. |

An analysis is complete when JETLS stopped at no top-level error, parse error included, and
logged no error of its own; turning a stop's diagnostic off in `.JETLSConfig.toml` hides the
diagnostic, not the stop. Files a complete analysis did not reach are noted and get
follow-up units. Diagnostics cover the analyzed code in its prepared environment; like any
static analysis they do not prove every possible specialization type-stable, and analyzing
a test file does not run its tests.

## Julia API

```julia
using JETSweep

inventory = discover("/path/to/workspace")
units = plan(inventory)
result = sweep("/path/to/workspace"; options=SweepOptions(jobs=16, fail_on=:warning))
result.exit_code
```

Loading JETSweep does not load JETLS; only analysis workers do.

## Development

```sh
julia --project -e 'using Pkg; Pkg.test()'
julia --project -e 'using Pkg; Pkg.test(test_args=["test_planning.jl"])'
```
