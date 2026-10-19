# JETSweep.jl

Recursively analyze a Julia workspace with one command:

```sh
jetsweep /path/to/workspace
```

JETSweep discovers packages, nested packages, tests, extensions, and standalone Julia
files. It prepares their dependency environments and runs full JETLS analysis in
isolated Julia processes. Findings, incomplete contexts, timeouts, exclusions, and
changed inputs remain explicit in the report.

The implementation is Julia throughout. No Python runner, captured workspace
inventory, or preinstalled `jetls` executable is required.

## Install and run

JETSweep requires Julia 1.13 or later. The current JETLS 2026.10.14 backend supports
Julia 1.13 and is pinned to its exact upstream release commit because its analysis
APIs are internal and version-specific. Later Julia releases require a compatible
JETLS backend update; Julia 1.12 is not supported.

From a local checkout:

```sh
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -m JETSweep /path/to/workspace
```

To install the `jetsweep` command from that checkout:

```julia
using Pkg
Pkg.Apps.develop(path="/path/to/JETSweep.jl")
```

Add `~/.julia/bin` to `PATH`. After the package is available on the repository's
default branch, it can also be installed with
`Pkg.Apps.add(url="https://github.com/AzamatB/JETSweep.jl")`.
See the [Julia package-app documentation](https://pkgdocs.julialang.org/dev/apps/)
for installation details.

```sh
# Preview discovery and the analysis plan without loading analyzed packages.
jetsweep --plan /path/to/workspace

# Parallel workers, each with two Julia threads; distribute GPU visibility.
jetsweep --jobs 12 --threads 2 --gpus 0,1,2,3 /path/to/workspace

# Explicit output location and no dependency downloads.
jetsweep --no-instantiate --output /tmp/my-audit /path/to/workspace
```

Defaults choose up to 12 workers from available CPU and RAM capacity. Environment
preparation is shared between jobs with the same dependency context. BLAS and OpenMP
threads are capped per worker to avoid nested oversubscription. Workers have a
1,200-second time limit; `--timeout 0` disables it. Timed-out process groups and their
children are terminated before their slots are reused.

JETLS inference analysis runs on the CPU. GPU assignment controls which devices
GPU-aware packages can see while being loaded or analyzed; it does not replace
device-code inference checks. `--gpus auto` respects an existing
`CUDA_VISIBLE_DEVICES`, otherwise uses `nvidia-smi` when available. `--gpus none`
hides CUDA devices. Neither CUDA.jl nor NVIDIA tooling is required for CPU workspaces.

## Discovery and environments

- Git repositories include tracked and nonignored untracked files in discovery by default.
  `--tracked-only` omits untracked files from the inventory; `--include-ignored`
  includes ignored files in discovery.
  Nested repositories and packages are discovered independently. Duplicate package
  names are distinguished by their source locations and UUIDs.
- Ordinary directories work without Git. VCS internals, dependency caches, and
  generated audit output directories are excluded and listed in the inventory.
  Hidden Julia source such as JLL `.pkg` helpers is retained. Symlink cycles are avoided.
- `JuliaProject.toml`, alternative package entry files, versioned manifests, test
  targets, separate test projects, and Julia workspaces are recognized.
- Existing dependency locks and explicit path/URL sources seed isolated scratch
  environments. Missing test or extension dependencies are resolved with Julia's
  package manager. The target's projects, manifests, preferences, and source files
  are not rewritten. Package build scripts and automatic precompilation are disabled
  during environment preparation.
- When the analyzer and target share dependencies, a compatible analyzer environment
  preserves the target's exact source/version identities and effective preferences.
  The pinned JETLS and private dependencies remain fixed. Incompatible requirements
  are reported as unavailable instead of silently analyzing with another version.
- Declared extensions load their parent and all trigger dependencies. The worker
  verifies their identities before analyzing the actual loaded extension.
- Package files outside the statically discovered include graph receive supplemental
  source jobs. These import the owning package and analyze the original file; the
  report identifies this context and does not invent a historical inclusion site.
  Files missed by a package or extension's actual analysis also receive supplemental
  source jobs. Their results do not erase an incomplete original package context.

Exclusions and Git tracking rules filter discovery. Package projects that remain
discovered still create package and declared extension jobs, even when an entry file
matches an exclusion. Those jobs can load and analyze excluded files through imports
and includes, and their diagnostics remain in the report. To omit a package's direct
jobs, exclude its entire directory, for example:

```sh
jetsweep --exclude Example.jl /path/to/workspace
```

Other analyzed packages can still load that package as a dependency.

Only explicit dependency declarations select sibling packages. An unrelated checkout
with a matching name is never silently substituted for a missing dependency.
Analysis workers reuse existing compiled caches and otherwise load source; they do not
generate new native package images or trigger package-image precompile workloads.

## Context configuration

Most files need no configuration. A `.JETSweep.toml` at the supplied root can specify
contexts for scripts that require arguments, setup files, or a different project.
Use `--config FILE` to select another configuration. Paths inside the file are relative
to its directory; matching uses paths relative to the supplied workspace root.

```toml
[[jobs]]
match = "Example.jl/test/test_special_*.jl"
project = "Example.jl/test"
setup = ["Example.jl/test/test_support.jl"]
args = ["small-fixture"]
env = { EXAMPLE_MODE = "analysis" }

[[jobs]]
match = "tools/check.jl"
project = "tools"
jetls_config = "tools/.JETLSConfig.toml"
```

Setup files run in the disposable analysis worker. Environment overrides apply to
analysis, not dependency resolution. Unknown configuration keys and patterns matching
no jobs are errors. Test jobs derive a declaration context from `runtests.jl` and
statically discovered containing files; omissions and unresolved contexts are recorded.
Dynamic include and code-generation notes remain visible even if JETLS resolves them.
Referenced JETLS configurations can adjust analysis contexts and concretization, but
must retain unfiltered diagnostics, disable native-inference reuse, and leave JETLS
automatic instantiation off. JETSweep manages dependency preparation itself.

Analysis can execute imports, macros, generated functions, and concretized setup.
Use JETSweep on code you trust. This is static analysis, not a sandbox or a functional
test runner; a completed test-file analysis does not mean its tests passed.

## Reports and exit codes

Each run writes a new directory, normally `.jetsweep/RUN/` beneath the analyzed root:

- `inventory.toml`: discovered projects, owned files, exclusions, and discovery issues.
- `plan.toml`: the initial jobs and their selected contexts.
- `supplemental-plan.toml`: fallback source jobs and their parent jobs, when analysis
  reveals missing package or extension coverage.
- `environments/`: dependency-preparation requests, results, and raw logs.
- `jobs/`: per-job requests, original-file coverage, diagnostics, tool provenance, and logs.
- `inputs-before.toml` and `inputs-after.toml`: source, metadata, configuration, and tool hashes.
- `report.toml`: combined results, file coverage, and deduplicated diagnostics.
- `summary.txt`: a readable summary and diagnostic listing.

All diagnostic severities are retained. `--fail-on` controls the exit threshold, not
which diagnostics are reported. The default is `hint`, which fails on any diagnostic.

| Exit | Meaning |
| --- | --- |
| 0 | Analysis completed with no diagnostics at or above the selected threshold. |
| 1 | Analysis completed with diagnostics meeting the threshold. |
| 2 | Some analysis was incomplete, unavailable, timed out, changed during the run, or failed. |
| 130 | The run was interrupted. |

`--fail-on none` never converts incomplete analysis into success. A package that cannot
load is recorded as unavailable or incomplete. JETLS include traversal, signature
analysis, and expected-file coverage are checked independently; a worker exiting
successfully is insufficient evidence of completion.

The report covers its recorded environments and analyzed signatures. It does not
prove type stability for every possible Julia specialization, check all device code,
or establish numerical correctness. Generic-signature findings can require concrete
workload investigation. JETLS startup preferences are isolated per worker and recorded;
the user's preferences are not changed.

## Julia API

```julia
using JETSweep

inventory = discover("/path/to/workspace")
jobs = plan(inventory)
result = sweep("/path/to/workspace";
    options=SweepOptions(jobs=8, threads=2, gpu_devices=["none"]))
result.exit_code
```

Importing JETSweep does not start a scan or load the analysis backend.

## Development

```sh
julia --project --check-bounds=yes --depwarn=error -e 'using Pkg; Pkg.test()'
```

Tests cover recursive discovery, dependency isolation, process lifecycle, reporting,
and real JETLS positive/negative controls for packages, tests, scripts, extensions,
and disconnected sources. Test selectors are available through
`Pkg.test(test_args=["test_backend.jl"])`.
