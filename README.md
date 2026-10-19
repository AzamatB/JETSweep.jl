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
jetsweep --jobs 24 --fail-on warning DIRECTORY  # 24 CPU slots; fail only on warnings and errors
jetsweep --exclude vendor --exclude '**/generated/*.jl' DIRECTORY
```

| Option | Meaning |
| --- | --- |
| `--jobs N` | CPU slots for parallel analyses. Default: the CPU threads, at most one per 3 GiB of memory. |
| `--threads N` | Threads for package and extension analyses, whose signature analysis is parallel (default 4). Other analyses run single-threaded. |
| `--timeout SECONDS` | Time limit per analysis or environment, 0 for none (default 1800). |
| `--gpus auto\|none\|LIST` | GPUs assigned round-robin through `CUDA_VISIBLE_DEVICES` (default `auto`: the visible devices). |
| `--output DIRECTORY` | Report directory, new or empty (default `DIRECTORY/.jetsweep/TIMESTAMP`). |
| `--config FILE` | Configuration file (default `DIRECTORY/.JETSweep.toml`, if present). |
| `--exclude GLOB` | Skip matching paths; repeatable. A pattern with `/`, or starting with `/` or `./`, matches the path relative to `DIRECTORY`; any other pattern matches a path segment. |
| `--include-ignored`, `--tracked-only` | Include files Git ignores; include only files Git tracks. |
| `--offline` | Use only packages that are already installed. |
| `--fail-on LEVEL` | Lowest severity that fails the run: `error`, `warning`, `info`, `hint` (default) or `none`. |

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
| Test driver | `test/runtests.jl` | Script analysis in the package's test environment. |
| Test file | any other test file | Script analysis after a prelude from its driver, for test files the driver includes at run time. |
| Script | any other file | Script analysis in its nearest environment; a package's own scripts use its test environment. |
| Orphan source | package or extension source that loading leaves out | Script analysis with the package's bindings and imports in scope, as if the package included it. |

Test drivers commonly choose their test files at run time, as in
`for file in (isempty(ARGS) ? ALL_TESTS : ARGS) include(file) end`, which static analysis cannot
follow. Each such test file therefore gets its own unit, analyzed after a prelude of the
driver's imports and definitions and the constants the test file refers to, copied with their
original source text; selection logic the test file does not depend on is left out. The
driver's own analysis evaluates exactly the assignments that select its files, to get past
the selection, and skips including the files analyzed separately.

Script analysis evaluates definitions but not assignments, so a definition or `include` that
needs an assigned value stops JETLS (`toplevel/missing-concretization`). JETSweep lets it
evaluate the top-level statements that cannot have side effects: assignments of literals,
paths and pure functions of names already bound, such as
`const ROOT = normpath(joinpath(@__DIR__, ".."))`, and definition guards such as
`if !@isdefined(Alias) const Alias = Package end`.

Files an analysis does not reach, such as package files loading leaves out or files after an
analysis stop, get follow-up units of their own, so every file is analyzed somewhere.

Every unit runs in a fresh worker process. Units with the same dependency context share one
prepared environment: a scratch project in the report directory that combines the
package's dependencies, its test dependencies (test target or `test/Project.toml`) or
extension triggers, `[sources]`, workspaces, compat bounds and effective preferences, with
the analyzer resolved alongside, so that packages both use, such as Revise, have one version.
Existing manifests seed the resolution, keeping locked versions where they are consistent;
when they are not, the environment is re-resolved and the report notes what changed. Each
environment is precompiled once for all its units. Original projects, manifests, preferences
and sources are never written, and package build scripts never run.

The scheduler prepares environments first, then starts the longest analyses, as measured by
the previous report in `DIRECTORY/.jetsweep` or estimated from source size, giving package
and extension analyses `--threads` CPU slots each, and assigns GPUs round-robin. Workers run
with Julia's default code generation flags, so they share the package images of ordinary
sessions. Analysis is static, but it loads packages and runs their initialization, macros and
generated functions, and the code JETLS evaluates to analyze scripts: use JETSweep only on
code you trust.

## Configuration

`.JETLSConfig.toml` files are respected: each unit uses the nearest one at or above its
entry, with paths relative to its directory, as in the editor, so severity overrides and
concretization patterns apply. JETSweep prepares environments itself, so it sets
`full_analysis.auto_instantiate = "never"`, and it keeps diagnostics enabled for all files.

An optional `.JETSweep.toml` at the root adds exclusions and context for units that need it,
such as scripts that expect arguments or a different environment. `exclude` and `match` are
globs relative to the root, and each `match` must select at least one unit by its entry file;
`project`, `setup` and `jetls_config` are paths relative to the configuration file. When
several tables match a unit, each key a later table sets overrides earlier ones.

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

The report directory contains `report.toml` (every unit's status, reasons and timing, and
the deduplicated diagnostics), `summary.txt` (the diagnostics as `file:line:column` with
messages, then the summary printed at the end of the run), the inventory and plan, and each
unit's and environment's request, result and log.

| Exit | Meaning |
| --- | --- |
| 0 | Every analysis completed, with no diagnostic at or above `--fail-on`. |
| 1 | Every analysis completed, with diagnostics at or above `--fail-on`. |
| 2 | An analysis was incomplete, timed out or failed, discovery found broken project metadata, or an input changed during the run. |
| 130 | Interrupted. |

An analysis is complete when it covered all files of its unit and stopped at no top-level
error. Diagnostics cover the analyzed code in its prepared environment; like any static
analysis they do not prove every possible specialization type-stable, and analyzing a test
file does not run its tests.

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
