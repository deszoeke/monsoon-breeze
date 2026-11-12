# Monsoon convection in Breeze.jl

EKAMSAT Arabian Sea monsoon convection in Breeze.jl, from an idealized sounding. The project began
as a translation of a CM1 (r21.1) case in `cm1/`; `notes/cm1_migration.md` maps the CM1 namelist to
Breeze and records where the setups differ.

**Contents:** [Quick start](#quick-start) · [Running the model](#running-the-model) ·
[Setup on a laptop](#setup-on-a-laptop-cpu) · [Setup on the HPC](#setup-on-the-hpc-gpu-with-cuda-slurm-partition-ceoas-gpu) ·
[Compiling](#compiling) · [New experiment](#writing-a-new-experiment) ·
[Troubleshooting](#troubleshooting) · [Reference](#reference): [files](#files), [domain and resources](#model-domain-and-resources),
[changes to Breeze defaults](#changes-to-breeze-defaults), [glossary](#glossary)

## Quick start

Laptop (CPU), once, then a 1 h check (16 km × 8 km, ~3 min):

```sh
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project setup_precompile.jl
mkdir -p run/small_test && cp monsoon_convection.jl run/small_test/
# in run/small_test/monsoon_convection.jl set  arch = :cpu  and  small_test = true, then
cd run/small_test && julia --project=../.. monsoon_convection.jl
```

HPC (GPU), once, **in this order** (details and the GPU check: [Setup on the HPC](#setup-on-the-hpc-gpu-with-cuda-slurm-partition-ceoas-gpu)):

```sh
git clone git@github.com:deszoeke/monsoon-breeze.git /ceoas/deszoeks/projects/monsoon-breeze && cd /ceoas/deszoeks/projects/monsoon-breeze
echo 'source /ceoas/deszoeks/projects/monsoon-breeze/helpers/arch_env.sh' >> ~/.bashrc    # Julia, depot, CPU target, Slurm per architecture
source helpers/arch_env.sh
# download the packages: once per architecture, on a node of that architecture
JULIA_PKG_PRECOMPILE_AUTO=0 julia --project -e 'using Pkg; Pkg.instantiate()'     # x86_64: here, on the login node
sbatch -p ceoas-arm instantiate_job.sh                                            # aarch64 (GH200): a batch job, log below
sbatch -p ceoas precompile_job.sh             # x86_64 (A100 nodes), ≈ 5 min; the log ends "Load check: ok"
sbatch -p ceoas-arm precompile_job.sh         # aarch64 (GH200 nodes): once per architecture you will run on
```

Then each experiment, from the repository directory on the login node:

```sh
mkdir -p run/exp && cp monsoon_convection.jl run/exp/     # edit the settings in the copy
sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh run/exp
sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 --time=2:00:00 monsoon_job.sh run/exp
```

## Running the model

Each experiment has a run directory holding **its own copy** of `monsoon_convection.jl`. The
settings block at the top of that copy (plain Julia assignments) is the whole run configuration:

```sh
mkdir -p run/exp && cp monsoon_convection.jl run/exp/   # then edit the settings in the copy
cd run/exp && julia --project=../.. monsoon_convection.jl
```

A queued batch job reads the copy when it starts, so editing the repository's file never changes
a submitted run, experiments can run side by side, and the run directory keeps the code that ran.
The copy finds `helpers/` and `cm1/` through the project (`--project`), wherever it is.

| Setting | Default | Meaning |
|---|---|---|
| **Run** | | |
| `arch` | `:gpu` | `:gpu` or `:cpu`. `:gpu` is checked (NVIDIA device, CUDA working) before the model loads, and the run stops at once if it fails. |
| `small_test` | `false` | 32×16 columns (16 km × 8 km), 1 h. A check that the code runs, not a scientific configuration. |
| `restart` | `false` | Continue from the latest checkpoint in the run directory (see Restarts). |
| `stop_time` | `7days`; `1hour` with `small_test` | **Total** simulated time, counted from the start of the original run. |
| `checkpoint_interval` | `1hour` (`30minutes` with `small_test`) | Model time between restart files. Only the latest is kept, and none is written when a run ends in NaN. |
| `debug_nan` | `false` | Every iteration, check prognostic **and** diagnostic fields for NaN/Inf and stop at the first, listing each bad field (fewest bad points first: nearest the origin). Every 10 iterations, print field extremes and the location, height and T of each bounds violation. |
| **Model** | | |
| `float_type` | `Float32` | Precision of the model. |
| `microphysics` | `:one_moment` | Mixed-phase one-moment, or `:p3` (not production ready; compiles at startup). |
| `sponge_variables` | `:w` | Upper sponge above 20 km. `:w` damps only w; `:all` also relaxes u, v and θ toward the sounding. |
| `sponge_timescale` | `300seconds` | Sponge damping time scale at the model top (sin² ramp from 20 km). |
| **Output** | | |
| `flux_outputs` | `true` | Vertical-flux diagnostics: resolved covariances (`wu`, `wv`, `wtheta`, `wq*`), closure fluxes (`F_*_sgs`) and sedimentation fluxes (`F_*_sed`) in `_profiles.nc`; surface fluxes (`F_*_sfc`) and bottom-face sedimentation (precipitation) maps in `_surface.nc`. `false` builds none of them, so they cost no compute or memory. |
| **Fixes to Breeze (keep on)** | | |
| `pressure_solver_type` | `Float64` | Precision of the pressure solve. A Float32 solve is unstable on the full 512 km domain ([Changes to Breeze defaults](notes/breeze_defaults.md), 3). |
| `implicit_rain_sink` | `true` with one-moment | Backward-Euler rain–snow collection sinks, which otherwise drive rain and snow negative (`helpers/implicit_rain_sink_correction.jl`, `issues/breeze_issue_uncapped_collection_sinks.md`). |
| **Stability options** (on in every tested run; not yet tested off with the fixes) | | |
| `sedimentation_cfl` | `true` | Also limit Δt by the hydrometeor fall speeds, so that (w + fall speed) Δt / Δz ≤ 0.7 ([notes](notes/breeze_defaults.md), 5). |
| `bounded_advection` | `true` | Bounds-preserving WENO for scalars; `false` gives Breeze's plain WENO(5) ([notes](notes/breeze_defaults.md), 4). |

Durations use `Oceananigans.Units`: `30minutes`, `1hour`, `4days`. Under Slurm the run stops and
checkpoints 10 min before the job's time limit (it reads `SLURM_JOB_END_TIME`); there is no limit
otherwise.

### Output files

Output and checkpoints are written to the run directory (where Julia runs). `<prefix>` is
`monsoon_convection`, or `monsoon_convection_small_test` with `small_test`.

| File | Content |
|---|---|
| `<prefix>_profiles.nc` | Horizontal means, averaged over each hour, (z, time); includes the vertical fluxes |
| `<prefix>_surface.nc` | Hourly snapshots at the lowest model level (z = 25 m), (x, y, 1, time); includes the surface fluxes |
| `<prefix>_fields.nc` | 3D snapshots, daily (every 30 min with `small_test`) |
| `<prefix>_checkpoint_iteration<N>.jld2` | Restart file (Julia format); only the latest is kept |

The NetCDF files have plain-ASCII variable names, with `units` and `long_name` attributes. They open
directly in Python (`xarray.open_dataset`), MATLAB (`ncread`), ncview, etc.

| Variable | Meaning | Units |
|---|---|---|
| `u`, `v`, `w` | wind components | m s⁻¹ |
| `theta` | liquid-ice potential temperature (equals θ in unsaturated air) | K |
| `T` | temperature | K |
| `qv` | specific humidity | kg kg⁻¹ |
| `qcl`, `qci`, `qr`, `qsn` | one-moment: cloud liquid, cloud ice, rain, snow mass fractions | kg kg⁻¹ |
| `ql`, `qi` | one-moment: total liquid and total ice mass fractions | kg kg⁻¹ |
| `qcl`, `qr`, `qi` | P3: cloud liquid, rain, total ice mass fractions | kg kg⁻¹ |
| `qf`, `qwi` | P3: rime mass and liquid water on ice, mass fractions | kg kg⁻¹ |
| `nr`, `ni` | P3: rain and ice number per mass of air | kg⁻¹ |
| `bf` | P3: rime volume per mass of air | m³ kg⁻¹ |
| `radiative_flux_divergence` | (profiles only) radiative heating × ρ cₚ | W m⁻³ |
| `w2` | (profiles only) vertical velocity variance | m² s⁻² |
| `wu`, `wv`, `wtheta`, `wq<species>` | (profiles) resolved vertical flux ⟨w′a′⟩, deviations from the horizontal mean, on z faces (`z_aaf`) | a × m s⁻¹ |
| `F_u_sgs`, `F_v_sgs`, `F_theta_sgs`, `F_<q>_sgs` | (profiles) subgrid (closure) vertical flux, on z faces | a × m s⁻¹ |
| `F_<q>_sed` | sedimentation flux ⟨q w_fall⟩ (negative downward); profiles, and at the bottom face (precipitation) in the surface file | kg kg⁻¹ m s⁻¹ |
| `F_u_sfc`, `F_v_sfc`, `F_theta_sfc`, `F_qv_sfc` | (surface) bulk boundary-condition fluxes, not covariances | a × m s⁻¹ |

All fluxes are kinematic and upward-positive; the resolved flux is zero at the bottom and top faces. The
total flux of a species at an interior face is `w<q> + F_<q>_sgs + F_<q>_sed`; at z = 0 it is `F_*_sfc`
(vapor, θ, momentum) and `F_<q>_sed` (precipitation). Details: `notes/STATUS.md`, "Flux outputs".

### Restarts

- A checkpoint is written every `checkpoint_interval` of model time, and whenever a run ends,
  at the stop time or 10 min before the Slurm job's time limit.
- `restart = true` resumes from the latest checkpoint in the run directory. Set it in the run's
  copy after the first job. The time step is recomputed from the CFL condition.
- `stop_time` is the **total** simulated time, not additional time. A run checkpointed at 24 h
  with `stop_time = 48hours` runs 24 more hours.
- On restart, output is **appended** to the existing NetCDF files (Oceananigans warns "already exists …
  Mode will be set to append"; expected). Appending to files from an older version that lack the
  flux variables may fail: restart into a fresh run directory instead.

## Setup on a laptop (CPU)

Tested with Julia 1.13.1 on an Apple M3 and on x86 (WSL). The Quick start commands are the whole
setup. `setup_precompile.jl` takes about 2.5 min the first time and seconds when nothing changed. The
first run of a fresh install also downloads the radiation and microphysics lookup tables, once per
Julia depot. To test a restart, run the small test, then set `restart = true` and `stop_time = 1.5hour`
in the copy and run it again.

## Setup on the HPC (GPU with CUDA, Slurm partition `ceoas-gpu`)

Commands assume the repository is cloned to `/ceoas/deszoeks/projects/monsoon-breeze` and runs go in a scratch
directory. Replace paths as needed. Use Julia 1.13.x on every machine (juliaup).

**1. Inspect the partition (once).** GPU request syntax, types and limits differ between clusters:

```sh
sinfo -p ceoas-gpu -o "%P %a %l %D %c %m %G"   # time limit, nodes, CPUs, memory, GPUs (GRES)
scontrol show partition ceoas-gpu               # defaults and limits
srun -p ceoas-gpu --gres=gpu:1 -t 0:05:00 nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
srun -p ceoas-gpu --gres=gpu:1 -t 0:05:00 curl -sI https://github.com | head -1   # internet on compute nodes?
```

- Use a GPU with at least 24 GB (see [domain and resources](#model-domain-and-resources)). If the
  partition mixes GPU types, request one, e.g. `--gres=gpu:a100:1` (`%G` in `sinfo` lists the names).
  Some clusters use `--gpus=1`.
- **No internet on compute nodes?** The lookup tables and the CUDA runtime download on first use.
  Trigger them once from a node that has internet, in that architecture's environment (step 2): `Pkg.instantiate()`,
  then `julia --project -e 'using CUDA'` after pinning the CUDA runtime (step 3).

**2. Environment and Julia depot (once per architecture, in this order).** The home directory is shared by the
x86_64 and aarch64 nodes, but Julia, its depot and compiled code are per architecture.
[`helpers/arch_env.sh`](helpers/arch_env.sh) sets them from `uname -m`: juliaup's Julia 1.13 (not the system
1.10), the depot (`~/.julia` on x86_64, `~/.julia-aarch64` on aarch64), `JULIA_CPU_TARGET` (`haswell,-rdrnd` on
x86_64 so that one cache serves every node; unset, i.e. native, on aarch64) and that architecture's Slurm
commands. The batch scripts source it themselves; your shells must too, **before** any `julia` command:

```sh
git clone git@github.com:deszoeke/monsoon-breeze.git /ceoas/deszoeks/projects/monsoon-breeze && cd /ceoas/deszoeks/projects/monsoon-breeze
echo 'source /ceoas/deszoeks/projects/monsoon-breeze/helpers/arch_env.sh' >> ~/.bashrc     # new shells, once
source helpers/arch_env.sh                                            # this shell
julia --version; echo "$JULIA_DEPOT_PATH  ${JULIA_CPU_TARGET:-native}  $(uname -m)"   # check: 1.13.x and the right depot
# download the pinned package versions; skip Pkg's automatic precompile, which would also
# compile CUDA.jl (that can fail on a login node without a GPU driver)
JULIA_PKG_PRECOMPILE_AUTO=0 julia --project -e 'using Pkg; Pkg.instantiate()'
```

Run the instantiate **once on each architecture you will use** (x86_64: the login node, as above; one run covers
`ceoas`, `ceoas-gpu` and the login node, which share `~/.julia`). **aarch64 needs its own run on an `ceoas-arm`
node** (the packages go into `~/.julia-aarch64`; the login node cannot fill it):

```sh
sbatch -p ceoas-arm instantiate_job.sh      # needs internet on the node (check with the `curl` line in step 1)
tail -f slurm-instantiate-<jobid>.out       # ends with "Instantiate done", or the error; squeue -u $USER shows it
```
Do **not** export `JULIA_DEPOT_PATH` or `JULIA_CPU_TARGET` yourself: the shared `~/.bashrc` would apply them to
both architectures (`haswell` is not a valid target on aarch64). A job that sees a different
`JULIA_CPU_TARGET` than the one a cache was built with rejects it and recompiles at startup. Without a tracked
manifest, `Pkg.instantiate` resolves one from the compat bounds. Avoid multi-target `JULIA_CPU_TARGET` strings:
they multiply the memory needed to precompile (five targets ran out of memory even on the login node).

**3. Precompile and check a GPU node.** All compiling happens on a compute node, which has the NVIDIA
driver and enough memory (the precompile needs about 6 GB, more than the login node allows):

```sh
sbatch -p ceoas precompile_job.sh       # x86_64 (for the A100 nodes)
sbatch -p ceoas-arm precompile_job.sh   # aarch64 (for the GH200 nodes)
```

No GPU is needed (32 GB, ≈ 5 min; log in `slurm-precompile-<jobid>.out`), but name a partition of the
architecture you are compiling for: x86_64 and aarch64 have separate Julia depots and caches
(`helpers/arch_env.sh` picks them from the node the job lands on), so run it once per architecture.

The log ends with `Load check: ok`. Then check the GPU interactively:

```sh
srun -p ceoas-gpu --gres=gpu:1 --cpus-per-task=4 --mem=32G --time=1:00:00 --pty bash -l   # or -p ceoas-arm --gres=gpu:gh200_480gb:1
cd /ceoas/deszoeks/projects/monsoon-breeze && source helpers/arch_env.sh   # the interactive shell needs it too (julia --version: 1.13.x)
nvidia-smi                                  # your GPU: ~0 MiB used, no other processes
julia --project check_gpu.jl                # CUDA, GPU context, model compiles and steps on the GPU
julia --project check_gpu.jl --smoke_test   # once before production: adds a 10-min end-to-end run
```

`check_gpu.jl` prints PASS/FAIL per stage and stops at the first failure with the real error. If
stage 1 says "CUDA is not functional", pin the CUDA runtime to the driver's version (stored in the
per-machine, git-ignored `LocalPreferences.toml`):

```sh
julia --project -e 'using CUDA; CUDA.set_runtime_version!(v"12.8")'   # version from nvidia-smi
```

For stage 2 ("GPU busy or not allocated to you") see [Troubleshooting](#troubleshooting). Rerun
the precompile (for each architecture) and `check_gpu.jl` after every `git pull` that changes `MonsoonConvection/src`,
and after package updates.

**4. Measure throughput (optional).** Run the full domain for one simulated hour in an interactive GPU session:

```sh
mkdir -p run/gpu_1h && cp monsoon_convection.jl run/gpu_1h/   # set stop_time = 1hour in the copy
cd run/gpu_1h && julia --project=../.. monsoon_convection.jl 2>&1 | tee gpu_1h.log
```

Watch memory with `nvidia-smi` in a second shell. The progress lines show wall time per 100 steps;
multiply by the expected number of steps (25,000–45,000) to estimate the full run.

**5. Production runs (batch).** Make the run directory with its copy of the driver, edit the copy's
settings, then submit [`monsoon_job.sh`](monsoon_job.sh) from the **repository directory** on the
**login node**. It takes only the run directory; the partition and GPU go on the `sbatch` line (its
header lists the partitions and working `sbatch` and `srun` lines):

```sh
cd /ceoas/deszoeks/projects/monsoon-breeze
mkdir -p run/exp && cp monsoon_convection.jl run/exp/          # edit run/exp/monsoon_convection.jl
sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp   # GH200 (aarch64), 96 GB GPU
sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh run/exp          # A100 (x86_64), 80 GB
# continue: set restart = true in run/exp/monsoon_convection.jl, then submit again
```

The script requests 2 CPUs, 32 GB and 2 h (for long runs pass `--time`, e.g. `sbatch --time=48:00:00 ...`),
sources [`helpers/arch_env.sh`](helpers/arch_env.sh) (juliaup's Julia 1.13 rather than the system 1.10,
that architecture's depot, `JULIA_CPU_TARGET` and Slurm commands; add it to `~/.bashrc` so interactive
shells match), stops at once if the allocated GPU has less than 40 GB free, and writes the log to
`<run directory>/slurm-<jobid>.out` (node, GPU, Julia version and the copy's settings, ending with
"Reached stop time …" or "Wall-time limit reached …").

- **Avoid `ceoas-arm-lowprio`.** A preempted job is requeued and reruns the copy as it is, from
  t = 0 unless `restart = true` is already set there.
- **Chained continuations** (`sbatch --dependency=afterok:$jid ...`) read the copy when they
  start, so set `restart = true` before the first job finishes.
- **The run stops 10 min before the job's time limit** and writes a checkpoint. Startup (compiling
  the GPU code, a few minutes) is inside the job's time.
- **Submit from the login node,** not from inside an interactive `srun` session, whose Slurm
  settings the job would inherit.

## Compiling

Julia compiles code the first time it runs; for this model that cost about 2.5 min before the first
time step. The setup:

- **Precompiled package, CPU warm-up.** All model and simulation setup lives in the package
  `MonsoonConvection`. During precompilation it runs a short warm-up on CPU (a 32×16×65 model: 3 steps,
  output, a checkpoint, a restart), so a CPU test starts in about 25 s instead of 154 s.
  `setup_precompile.jl` is the same on every machine.
- **GPU code compiles at startup.** There is deliberately no GPU precompile (an earlier version failed in
  hard-to-see ways and could not be tested without a GPU). A few minutes of compiling costs under 0.5% of
  a 47 h job. `check_gpu.jl` builds the model on the GPU and takes steps, reporting PASS/FAIL per stage.
- **Experiments are values, not code.** Compiled code depends on the *types* of the inputs, not their
  *values*: the sounding is plain vectors (`Sounding`), the geostrophic wind a precomputed field. Changing
  the sounding, initial conditions, grid size or parameters reuses the cache.
- **Hardware is requested, never auto-detected** (`arch = :cpu | :gpu`). A `:gpu` request halts before any
  package loads if no working GPU is present. CUDA is loaded only for `gpu`, and never by `setup_precompile.jl`.
- **Compile on a compute node,** with the one portable CPU target. The login node only does `git pull`
  and downloads. Both setup scripts end with a fresh-process load check and exit non-zero on failure, since
  Pkg's summary can report "✗" and still succeed.

| Change | Recompile? |
|---|---|
| Sounding values or levels, initial conditions, perturbations | No |
| Grid size, parameter values passed to `build_model` / `build_simulation`, run flags (e.g. `flux_outputs`) | No (a full-size grid compiles a few extra kernels at run time) |
| Editing `MonsoonConvection/src`, even comments | Yes, the package (≈ 2 min) |
| Microphysics or turbulence-closure *type*, new forcing kinds (edits in the package) | Yes, the package |
| Package updates (`Pkg.update`) or a new Julia version | Yes |
| A different CPU type (laptop vs. HPC node) | Separate cache per CPU type; they coexist |

After any change that recompiles, run `setup_precompile.jl` again (and `check_gpu.jl` on the cluster)
before production runs.

## Writing a new experiment

Copy `monsoon_convection.jl` and edit only the driver: its settings block, and the sounding section for a
new sounding.

- **Sounding.** For the EKAMSAT experiments, build the sounding from the control with the
  functions in `helpers/ekamsat_soundings.jl`; the driver shows how, and
  `cm1/soundings/README.md` describes each experiment. Otherwise read a CM1-format file, or write
  profiles as anonymous functions of height and *evaluate* them on a vector of heights:

  ```julia
  sounding = read_cm1_sounding("path/to/input_sounding")       # CM1 isnd = 7 format
  z = collect(0.0:100.0:40000.0)
  θ = z -> 300 + 4e-3z;  r = z -> 0.018exp(-z / 2500);  u = z -> -5.0;  v = z -> 0.0
  sounding = Sounding(101000.0, z, θ.(z), r.(z), u.(z), v.(z))  # r = vapor MIXING RATIO (kg/kg)
  ```

- **Grid and physical parameters** are keyword values of `build_model`, e.g.
  `build_model(sounding; arch, Nx, Ny, Δx = 250, sea_surface_temperature = 302, CO₂ = 420e-6)`.
  Pass `z_faces` as a `Vector` (`collect(...)`), not a range.
- **Initial conditions.** Use `set_initial_conditions!(model, sounding)`, or `set!` with functions of
  `(x, y, z)`. `set!` expects `θ` (liquid-ice potential temperature), `qᵗ` (total-water **specific
  humidity**, qᵗ = r / (1 + r)), `u` and `v`.

None of these recompile the package. Changing a physics *scheme* is done in the "Model" section of
`MonsoonConvection/src/MonsoonConvection.jl` and does recompile.

## Troubleshooting

Failures met while setting up the cluster, with causes and fixes:

- **"GPU requested, but no NVIDIA GPU was found"**: you're on a node without a GPU (e.g. the login node).
  Move to a GPU allocation (`srun ... --gres=gpu:1`) or set `arch = :cpu`. Nothing was changed.
- **"CUDA is not functional"** (or "CUDA.jl could not find an appropriate CUDA runtime"): CUDA's runtime
  package was compiled on a node without a driver (the login node) and recorded "no runtime". Pin the
  runtime version on the GPU node as `check_gpu.jl` instructs. Avoid it by never precompiling on the login
  node; install there with `JULIA_PKG_PRECOMPILE_AUTO=0 julia --project -e 'using Pkg; Pkg.instantiate()'`.
- **"Out of GPU memory" while creating a context** (stack trace through `cuDevicePrimaryCtxRetain`), even
  for a tiny model: the GPU is in use by another process, or your shell has no GPU allocated. Check
  `echo $SLURM_JOB_GPUS $CUDA_VISIBLE_DEVICES` (empty means no allocation), `nvidia-smi` and
  `ps -u $USER -f | grep julia` (leftover sessions). Start a fresh `srun ... --gres=gpu:1`.
- **LLVM "out of memory" or `ProcessSignaled(9)` while precompiling**: the precompile needs about 6 GB;
  login nodes usually allow less, and a multi-target `JULIA_CPU_TARGET` multiplies the need. Use
  `sbatch -p ceoas precompile_job.sh` (32 GB; `-p ceoas-arm` for aarch64) and, on x86_64, the single target
  `JULIA_CPU_TARGET="haswell,-rdrnd"` (aarch64 uses the native target).
- **NaN in P3 ice number above 23 km after ~15 min (or later), preceded by a growing top-cell temperature
  spread and max `Kᵘ` at the cap at 27.5 km** (`debug_nan = true`): the Float32 instability from a
  Float32 pressure solve. Keep the default `pressure_solver_type = Float64` (check that the run's copy
  doesn't set Float32). See [Changes to Breeze defaults](notes/breeze_defaults.md), 3.
- **CUDA out of memory during a full-size run** (not at context creation): the GPU is too small for the full
  domain (≈ 15 GiB in the default mixed precision, ≈ 30 GiB all-Float64). Request a larger GPU type, or
  reduce `Nx`, `Ny` in the driver.
- **Wrong Julia, depot or CPU target in a login or interactive shell** (`julia --version` says 1.10, or `JULIA_DEPOT_PATH`
  or `JULIA_CPU_TARGET` is not what `helpers/arch_env.sh` sets): `source helpers/arch_env.sh` (it belongs in
  `~/.bashrc`). Work done in such a shell compiles for the wrong version or target. It writes extra cache
  entries that the jobs do not use, so they recompile at startup, but it does not corrupt the correct ones.
- **"Precompiling MonsoonConvection" appears on every run**: `JULIA_CPU_TARGET` and `JULIA_DEPOT_PATH` must be
  identical at precompile time and run time. Source `helpers/arch_env.sh` in every shell (the batch scripts do),
  and make sure nothing edits `MonsoonConvection/src`.
- **Leftover `[MonsoonConvection] precompile_gpu` in `LocalPreferences.toml`**: from an earlier version;
  nothing reads it now. Delete that section, and keep the `CUDA_Runtime_jll` entry.

## Reference

### Files

| File | Purpose |
|---|---|
| `monsoon_convection.jl` | Experiment driver: sounding, initial conditions, grid size, run settings. Edit freely. |
| `MonsoonConvection/` | Local package with the model setup, output and restart logic. Precompiled. |
| `setup_precompile.jl` | Precompiles `MonsoonConvection` (CPU warm-up run) and checks that it loads. Same on every machine. |
| `instantiate_job.sh` | Slurm batch job that downloads the pinned packages (`Pkg.instantiate`) into the depot of the node's architecture; run once per architecture (`-p ceoas-arm` for aarch64). |
| `precompile_job.sh` | Slurm batch job that runs `setup_precompile.jl` on a compute node with enough memory; no GPU needed, but name a partition of the architecture to compile for (`-p ceoas` x86_64, `-p ceoas-arm` aarch64). |
| `check_gpu.jl` | Staged check that a GPU node can run the model; `--smoke_test` adds a 10-min run, `--cpu` tests the script without a GPU. |
| `monsoon_job.sh` | Slurm batch script for GPU runs: `sbatch -p <partition> --gres=<gpu> monsoon_job.sh <run directory>`. |
| `helpers/` | `preflight.jl` (flags and the GPU check, before any package loads), `pressure_solver_precision.jl` (run-time override giving the pressure solve its own precision; a stopgap until Breeze offers this), `arch_env.sh`, soundings and graph helpers. |
| `Project.toml` | Julia environment. Package versions are bounded by the compat entries in `MonsoonConvection/Project.toml`; each machine keeps its own untracked `Manifest.toml`. |
| `LocalPreferences.toml` | Per-machine settings, e.g. the pinned CUDA runtime version on the cluster (git-ignored). |
| `run/` | Run directories for output and checkpoints (git-ignored except each run's driver copy). |
| `plots/` | Readers, diagnostics and notebooks for the output (CairoMakie, PythonPlot). |
| `notes/`, `issues/` | Status, design notes, Breeze issues and the flux-diagnostics PR guide. |
| `cm1/` | Original CM1 namelist, sounding and log. |

### Model domain and resources

| | Full run | `small_test = true` |
|---|---|---|
| Columns (Nx × Ny) | 1024 × 512 | 32 × 16 |
| Horizontal extent | 512 km × 256 km, Δx = Δy = 500 m | 16 km × 8 km |
| Vertical | 58 levels to 28 km: Δz = 50 m at the surface, stretching linearly to 500 m at 5 km, 500 m to 18 km, then stretching to ~1 km at the lid | same |
| Grid cells | 30.4 million | 29,696 |
| Boundaries | periodic in x and y; rigid lid with a sponge above 20 km | same |
| Rotation | f-plane, f = 2.53 × 10⁻⁵ s⁻¹ (10°N) | same |
| Simulated time | `stop_time` | 1 h |
| Time step | adaptive, CFL 0.7, at most 15 s (≈ 8 s in the 1 h tests, before deep convection) | same |
| Time steps | roughly 25,000–45,000 | ≈ 570 |

**Memory** (estimates from `Base.summarysize` at 32×16 and 64×64, extrapolated linearly; check with
`nvidia-smi` in the first GPU run). The model plus simulation state is about 111 3D arrays, about 444 bytes
per grid cell including halos in Float32 (the GPU default), twice that in Float64:

| Configuration | Model state |
|---|---|
| Full run, Float32 model + Float64 pressure solve (GPU default) | **≈ 15 GiB**, plus a few GB of Float64 pressure-solve arrays |
| Full run, all Float64 | ≈ 30 GiB |
| `small_test`, Float32 (measured) | ≈ 54 MiB |

Allow headroom for the CUDA context and temporary arrays: the full domain needs a GPU with **at least
24 GB** in the default mixed precision, or 48 GB all-Float64; the A100 80 GB is comfortable either way.
Host memory needs are modest (output is copied to the host, ≈ 2 GB per 3D snapshot; 32–64 GB is ample).

**Disk** (estimates for the full run, per experiment):

| File | Size |
|---|---|
| `_fields.nc`: 14 variables × 30.4 M cells × 4 B per daily snapshot, 5 snapshots | ≈ 2 GB each, ≈ 10 GB total |
| `_surface.nc`: hourly, about 96 snapshots | ≈ 3 GB (more with the surface-flux and sedimentation variables) |
| `_profiles.nc` | < 10 MB (more with the flux profiles) |
| Checkpoint (JLD2, only the latest kept) | a few GB |

**Wall-clock time.** GPU throughput on the full domain is about 0.67 s per step in the default mixed
precision on an A100, 1.3 s all-Float64 (see [Changes to Breeze defaults](notes/breeze_defaults.md), 3).
On a laptop CPU the small test runs at about 0.27 s per step. Time a short full-size GPU run first
(step 4 of the HPC setup) to choose the job's `--time`.

### Changes to Breeze defaults

`MonsoonConvection` departs from Breeze's defaults or usual practice in the places below. Keep them in mind when
interpreting results or comparing with other Breeze runs. The reasons, evidence and effects are in
**[`notes/breeze_defaults.md`](notes/breeze_defaults.md)**.

1. **TKE closure diffusivities capped at 100 m² s⁻¹** (safeguard; changes the physics only where K would
   exceed the cap). `maximum_diffusivity` in `build_model`; `Inf` restores Breeze's default.
2. **Microphysics built on the target architecture** (bug workaround, no physics change; Breeze #1051, fixed on main
   by #1076). The default microphysics is the mixed-phase one-moment scheme, not P3 (`microphysics = :p3`).
   The vertical grid above 18 km (`Δz_top`) is also in the driver.
3. **Float64 pressure solve** (`pressure_solver_type`, default `Float64`): a Float32 solve is unstable on the full
   512 × 256 km domain. On GPU the rest of the model runs in Float32 (about 2× faster than all-Float64); on CPU
   everything is Float64.
4. **Bounded (positivity-preserving) WENO** for every advected scalar (`bounded_advection`), so that
   moisture, hydrometeors and numbers cannot go negative (negative values can make P3 return NaN).
5. **Fall speeds in the time-step limit** (`sedimentation_cfl`): Breeze's time-step wizard ignores hydrometeor fall
   speeds, which exceed the CFL limit in the 50 m lowest cell.

### Glossary

- **Precompilation**: Julia compiles a package ahead of time and stores the result (a *package image*) in the
  depot, so later sessions load compiled code.
- **Warm-up run**: a short model run executed *during* precompilation so that the code it exercises is
  compiled and cached; it is about which code gets cached, not about hardware.
- **Compile cache / depot**: where precompiled packages live (`~/.julia` by default; `JULIA_DEPOT_PATH` to
  change). Caches are specific to the Julia version, package versions, CPU type and preferences.
- **Preference** (`LocalPreferences.toml`): a per-machine setting read at compile time, e.g. CUDA's pinned
  runtime version.
- **CUDA context**: the per-process state CUDA creates on the GPU at the first GPU operation; creating it
  fails if the GPU is busy or not allocated to you.
- **Checkpoint**: a file with the full model state, used to restart a run.
