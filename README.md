# Monsoon convection in Breeze.jl

A Breeze.jl version of the CM1 (r21.1) EKAMSAT Arabian Sea monsoon-convection case in
`cm1/`: the 17 June 2023 sounding with a dry layer at 4800–7200 m and strong low-level shear,
adapted from CM1 `cpm_RadConvEquil`. The header of `monsoon_convection.jl` lists how each
CM1 namelist option maps to Breeze.

## Quick start

```sh
# laptop (CPU), once:
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project setup_precompile.jl

# quick check that everything runs (16 km × 8 km domain, 1 simulated hour, ~3 min):
mkdir -p run/small_test && cd run/small_test
julia --project=../.. ../../monsoon_convection.jl --small_test
```

## Files

| File | Purpose |
|---|---|
| `monsoon_convection.jl` | Experiment driver: sounding, initial conditions, grid size, run settings. Edit freely. |
| `MonsoonConvection/` | Local package with the model setup, output and restart logic. Precompiled. |
| `setup_precompile.jl` | Precompiles `MonsoonConvection` (CPU warm-up run) and checks that it loads. Same on every machine. |
| `check_gpu.jl` | Staged check that a GPU node can run the model: CUDA, GPU context, model compiles and steps on the GPU; `--smoke_test` adds a 10-min run. |
| `monsoon_job.sh` | Slurm batch script for GPU runs on partition `ceoas-gpu`; output goes to `run/` by default. |
| `preflight.jl` | Command-line parsing and the quick hardware check, run before any package loads. |
| `Project.toml`, `Manifest.toml` | Julia environment with pinned package versions. |
| `LocalPreferences.toml` | Per-machine settings, e.g. the pinned CUDA runtime version on the cluster (git-ignored). |
| `run/` | Local run directory for output and checkpoints (git-ignored; created by the scripts). |
| `cm1/` | Original CM1 namelist, sounding and log. |
| `test_checkpoint.jl` | Small 2D Breeze checkpoint/restart example (independent of the above). |

## Model domain and resources

| | Full run | `--small_test` |
|---|---|---|
| Columns (Nx × Ny) | 1024 × 512 | 32 × 16 |
| Horizontal extent | 512 km × 256 km, Δx = Δy = 500 m | 16 km × 8 km |
| Vertical | 65 levels to 28 km: Δz = 50 m at the surface, stretching linearly to 500 m at 5 km, then 500 m (identical to CM1 `zf`) | same |
| Grid cells | 34.1 million | 33,280 |
| Boundaries | periodic in x and y; rigid lid with a sponge above 20 km | same |
| Rotation | f-plane, f = 2.53 × 10⁻⁵ s⁻¹ (10°N) | same |
| Simulated time | 345,700 s ≈ 4 days (CM1 `timax`) | 1 h |
| Time step | adaptive, CFL 0.7, at most 15 s (≈ 8 s in the 1 h tests, before deep convection) | same |
| Time steps | roughly 25,000–45,000 | ≈ 570 |

**Memory.** The model plus simulation state takes about 111 Float32 3D arrays, about 444 bytes
per grid cell including halos. This was measured with `Base.summarysize` at 32×16 and 64×64 and
extrapolated linearly:

| Configuration | Model state |
|---|---|
| Full run, Float32 (GPU default) | **≈ 17 GiB** of GPU memory |
| Full run, Float64 | ≈ 34 GiB |
| `--small_test`, Float32 (measured) | ≈ 54 MiB |

Allow headroom for the CUDA context and temporary arrays. A GPU with **at least 24 GB** should
be enough, and 40–80 GB (A100, H100, L40S) is comfortable. A 16 GB GPU will not hold the full
domain.

These are estimates; check them with `nvidia-smi` during the first GPU run. Host memory needs
are modest. Output is copied to the host before writing (≈ 2 GB per 3D snapshot), so 32–64 GB
of host RAM is ample.

**Disk** (estimates for the full run; one run directory per experiment):

| File | Size |
|---|---|
| `_fields.nc`: 14 variables × 34.1 M cells × 4 B per daily snapshot, 5 snapshots | ≈ 2 GB each, ≈ 10 GB total |
| `_surface.nc`: hourly, about 96 snapshots | ≈ 3 GB |
| `_profiles.nc` | < 10 MB |
| Checkpoint (JLD2, only the latest kept) | a few GB |

**Wall-clock time.** GPU throughput for this configuration hasn't been measured yet. On a
laptop CPU, the small test runs at about 0.27 s per step. Time a short full-size GPU run first
(see "First GPU test" below) to choose `--wall_time` and the job's `--time`.

## Running the model

```sh
julia --project=<path/to/breeze> <path/to/breeze>/monsoon_convection.jl [flags]
```

| Flag | Default | Meaning |
|---|---|---|
| `--arch=cpu\|gpu` | `cpu` | Hardware to run on. A `gpu` request is checked (NVIDIA device present, CUDA working) before any package loads; if unavailable the run stops immediately and nothing is changed. |
| `--float=Float32\|Float64` | Float32 on GPU, Float64 on CPU | Floating-point precision. Single precision is standard for GPU runs of this kind. The precompile warm-up covers CPU Float64 runs. |
| `--small_test` | off | 32×16 columns (16 km × 8 km), 1 h. A check that the code runs, not a scientific configuration. |
| `--restart` | off | Continue from the latest checkpoint in the current directory (see Restarts). |
| `--stop_time=96h` | 345700 s ≈ 96 h (CM1 `timax`); 1 h with `--small_test` | **Total** simulated time, counted from the start of the original run. Units: `d`, `h`, `min`, `s`. |
| `--wall_time=47h` | none | Real (wall-clock) time limit for this job. The run stops cleanly and writes a checkpoint. |

Flags may use hyphens or underscores (`--small-test` is the same as `--small_test`). Unknown or
malformed flags stop the script within a second, with a short message.

### Run directory and output

Output and checkpoints are written to the directory you launch from, and `--restart` looks for
checkpoints there. Use one run directory per experiment, on a scratch filesystem on HPC.

| File | Content |
|---|---|
| `<prefix>_profiles.nc` | Horizontal means, averaged over each hour |
| `<prefix>_surface.nc` | Hourly snapshots at the lowest model level (z = 25 m) |
| `<prefix>_fields.nc` | 3D snapshots, daily (every 30 min with `--small_test`) |
| `<prefix>_checkpoint_iteration<N>.jld2` | Restart file (Julia format); only the latest is kept |

`<prefix>` is `monsoon_convection`, or `monsoon_convection_small_test` with `--small_test`.

The NetCDF files have plain-ASCII variable names, with `units` and `long_name` attributes:

| Variable | Meaning | Units |
|---|---|---|
| `u`, `v`, `w` | wind components | m s⁻¹ |
| `theta` | liquid-ice potential temperature (equals θ in unsaturated air) | K |
| `T` | temperature | K |
| `qv` | specific humidity | kg kg⁻¹ |
| `qcl`, `qr`, `qi` | P3 microphysics: cloud liquid, rain, total ice mass fractions | kg kg⁻¹ |
| `qf`, `qwi` | P3: rime mass and liquid water on ice, mass fractions | kg kg⁻¹ |
| `nr`, `ni` | P3: rain and ice number per mass of air | kg⁻¹ |
| `bf` | P3: rime volume per mass of air | m³ kg⁻¹ |
| `radiative_flux_divergence` | (profiles only) radiative heating × ρ cₚ | W m⁻³ |
| `w2` | (profiles only) vertical velocity variance | m² s⁻² |

They open directly in Python (`xarray.open_dataset`), MATLAB (`ncread`), ncview, etc.

### Restarts

- A checkpoint is written every simulated day (every 30 min with `--small_test`). One is also
  written whenever a run ends, whether at the stop time or at the wall-time limit.
- `--restart` resumes from the latest checkpoint in the current directory. The time step is
  recomputed from the CFL condition rather than restarting small.
- `--stop_time` is the **total** simulated time, not additional time. A run checkpointed at
  24 h and restarted with `--stop_time=48h` runs 24 more hours.
- On restart, output is **appended** to the existing NetCDF files.
- On HPC, set `--wall_time` a little below the job's time limit so the run stops and
  checkpoints before the scheduler kills it. Continue in a new job with
  `--restart --wall_time=...`.

## Compile-run strategy

Julia compiles code the first time it runs. For this model that cost about 2.5 min before the
first time step of every run. The setup is:

1. **Precompiled package, CPU warm-up.** All model and simulation setup lives in the package
   `MonsoonConvection`. During precompilation it executes a short **warm-up run** on CPU: a
   32×16×65 model that takes 3 steps, writes output and a checkpoint, and restarts from it.
   Julia caches the compiled code, so a CPU test starts in about 25 s instead of 154 s.
   `setup_precompile.jl` is the same on every machine.
2. **GPU jobs compile their GPU code at startup.** There is deliberately no GPU precompile
   step. On a 47 h job, a few minutes of compiling cost under 0.5%. An earlier version
   precompiled a GPU warm-up inside a package extension. It failed in ways that were hard to
   see (see Troubleshooting) and couldn't be tested without a GPU, so it was removed.
3. **Check the real path.** `check_gpu.jl` builds the model on the GPU and takes time steps.
   It reports PASS/FAIL per stage with the real error. Both setup scripts end with a
   fresh-process check and exit non-zero on failure, because Pkg's summary can report "✗"
   and still succeed.
4. **Experiments are values, not code.** Compiled code depends on the *types* of the inputs,
   not their *values*. The sounding is passed as plain vectors (`Sounding`), and the
   geostrophic wind is read from a precomputed field. Changing the sounding (values or number
   of levels), initial conditions, grid size or parameter values therefore reuses the cache.
5. **Hardware is requested, never auto-detected.** `--arch=cpu|gpu`. A quick check halts a
   `gpu` request before any package loads if no working GPU is present. CUDA is loaded only
   for `gpu`, and is never compiled by `setup_precompile.jl`.
6. **Compile where you run.** On the cluster, compile on a GPU node, which has the driver and
   enough memory. The login node only does `git pull` and downloads packages.

### What triggers recompilation

| Change | Recompile? |
|---|---|
| Sounding values or levels, initial conditions, perturbations | No |
| Grid size, parameter values passed to `build_model` / `build_simulation`, run flags | No (a full-size grid compiles a few extra kernels at run time) |
| Editing `MonsoonConvection/src`, even comments | Yes, the package (≈ 2 min) |
| Microphysics or turbulence-closure *type*, new forcing kinds (edits in the package) | Yes, the package |
| Package updates (`Pkg.update`) or a new Julia version | Yes |
| A different CPU type (laptop vs. HPC node) | Separate cache per CPU type; they coexist |

After any change that recompiles, run `setup_precompile.jl` again (and `check_gpu.jl` on the
cluster) before production runs.

## PC / laptop setup (CPU)

Tested with Julia 1.13.1 on an Apple M3.

```sh
cd /path/to/breeze
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project setup_precompile.jl    # about 2.5 min once; seconds when nothing changed
```

The first run of a fresh install also downloads the radiation and microphysics lookup tables,
once per Julia depot.

```sh
mkdir -p run/small_test && cd run/small_test
julia --project=../.. ../../monsoon_convection.jl --small_test                       # 1 h
julia --project=../.. ../../monsoon_convection.jl --small_test --restart --stop_time=1.5h
```

## HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)

Commands assume the repository is cloned to `~/monsoon-breeze` and runs go in a scratch
directory. Replace paths as needed.

### 0. Inspect the partition (once)

GPU request syntax, GPU types and limits differ between clusters, so check before writing jobs:

```sh
sinfo -p ceoas-gpu -o "%P %a %l %D %c %m %G"   # time limit, nodes, CPUs, memory, GPUs (GRES)
scontrol show partition ceoas-gpu               # defaults and limits
srun -p ceoas-gpu --gres=gpu:1 -t 0:05:00 nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
srun -p ceoas-gpu --gres=gpu:1 -t 0:05:00 lscpu | grep "Model name"
srun -p ceoas-gpu --gres=gpu:1 -t 0:05:00 curl -sI https://github.com | head -1   # internet on compute nodes?
```

- Use a GPU with at least 24 GB of memory (see "Model domain and resources"). If the partition
  mixes GPU types, request one explicitly, e.g. `--gres=gpu:a100:1`. The type names are shown
  in the `%G` column of `sinfo`.
- Some clusters use `--gpus=1` instead of `--gres=gpu:1`.
- **No internet on compute nodes?** Lookup tables and the CUDA runtime are downloaded on first
  use. Trigger the downloads once from the login node: run `Pkg.instantiate()` (step 1), then
  `julia --project -e 'using CUDA'` after pinning the CUDA runtime version (step 2).

### 1. Environment and Julia depot (login node)

```sh
git clone git@github.com:deszoeke/monsoon-breeze.git ~/monsoon-breeze
cd ~/monsoon-breeze
export JULIA_DEPOT_PATH=/path/to/shared/julia_depot   # optional; put this in ~/.bashrc
# download the pinned package versions; skip Pkg's automatic precompile of everything,
# which would also compile CUDA.jl (that can fail on a login node without a GPU driver)
JULIA_PKG_PRECOMPILE_AUTO=0 julia --project -e 'using Pkg; Pkg.instantiate()'
```

Use the same Julia version as `Manifest.toml` (1.13.x); juliaup makes this easy.

**CPU type.** Compile caches are keyed by CPU type, and caches for different CPUs coexist in
the depot. Since all compiling happens on the GPU nodes, leave `JULIA_CPU_TARGET` **unset**
(native CPU); remove it from `~/.bashrc` if you set it earlier. Multi-target strings multiply
the memory needed to precompile.

### 2. Set up and check a GPU node (interactive)

All compiling happens here: the GPU node has the NVIDIA driver and enough memory (precompiling
needs about 6 GB, more than a login node usually allows).

```sh
srun -p ceoas-gpu --gres=gpu:1 --cpus-per-task=4 --mem=32G --time=1:00:00 --pty bash -l
cd ~/monsoon-breeze
nvidia-smi                                  # your GPU: ~0 MiB used, no other processes
echo $SLURM_JOB_GPUS $CUDA_VISIBLE_DEVICES  # set inside a GPU allocation

julia --project setup_precompile.jl         # CPU warm-up + load check (≈ 3–5 min)
julia --project check_gpu.jl                # stages 1–2: CUDA, GPU context, model compiles and steps
julia --project check_gpu.jl --smoke_test   # once before production: adds a 10-min end-to-end run
```

`check_gpu.jl` prints PASS/FAIL per stage and stops at the first failure with the real error.

- **Stage 1a fails with "CUDA.functional() is false":** the message gives the fix, which is to
  pin the CUDA runtime to the driver's version, e.g.

  ```sh
  julia --project -e 'using CUDA; CUDA.set_runtime_version!(v"12.8")'   # version from nvidia-smi
  ```

  The pin is stored in `LocalPreferences.toml`, which is per machine and git-ignored.
- **Stage 1b fails with "could not create a CUDA context":** the GPU is busy or not allocated
  to your shell. See Troubleshooting.

Rerun `setup_precompile.jl` and `check_gpu.jl` after every `git pull` or package update.

### 3. Measure throughput (interactive, optional)

```sh
mkdir -p ~/monsoon-breeze/run/gpu_1h && cd ~/monsoon-breeze/run/gpu_1h
julia --project=$HOME/monsoon-breeze $HOME/monsoon-breeze/monsoon_convection.jl --arch=gpu --stop_time=1h 2>&1 | tee gpu_1h.log
```

This runs the full domain for one simulated hour. Watch memory with `nvidia-smi` in a second
shell. The progress lines show wall time per 100 steps; multiply by the expected number of
steps (25,000–45,000) to estimate the length of the full run.

### 4. Production runs (batch)

Use the job script [`monsoon_job.sh`](monsoon_job.sh) in the repository. Output and
checkpoints go to the run directory `RUN`, by default `run/` in the repository (git-ignored).
The Slurm log `slurm-<jobid>.out` goes to the directory you submit from:

```sh
cd ~/monsoon-breeze
sbatch monsoon_job.sh                   # first job
sbatch monsoon_job.sh --restart         # each continuation job, until the stop time
# or chain a continuation behind the first job:
jid=$(sbatch --parsable monsoon_job.sh)
sbatch --dependency=afterok:$jid monsoon_job.sh --restart

# a second experiment in its own run directory:
RUN=$HOME/monsoon-breeze/run/sst302 sbatch monsoon_job.sh
```

A restart resumes from the latest checkpoint in `RUN`, so give each experiment its own `RUN`.
On HPC, `RUN` can also point to a scratch filesystem if the repository's disk is small.

What the script does:
- Requests `-p ceoas-gpu`, 1 GPU, 4 CPUs, 64 GB of host memory and 48 h. Edit the `#SBATCH`
  lines to match step 0, or override at submission, e.g. `sbatch --time=24:00:00 ...` with
  `WALL_TIME=23h`.
- Runs `monsoon_convection.jl --arch=gpu --wall_time=$WALL_TIME` (default `47h`). Any
  arguments after the script name are passed through, e.g. `--restart` or `--stop_time=96h`.
- Assumes the repository is at `~/monsoon-breeze`; override with `REPO=/other/path sbatch ...`.
  The run directory defaults to `$REPO/run`; override with `RUN=...`.
- Logs the node, GPU, Julia version and repository commit at the start of the job.
- `JULIA_DEPOT_PATH` and `JULIA_CPU_TARGET` lines are commented out in the script. Enable them
  if you set them when precompiling.

Notes:
- Keep `WALL_TIME` about 1 h below `--time`. That leaves room for startup (CUDA kernel
  compilation, lookup tables) and the final checkpoint write.
- `srun` inside the batch script binds the job step to the allocated GPU. `nvidia-smi` in the
  job's log, or `ssh` to the node, shows usage.
- A continuation job must run in the same run directory and with the same `--stop_time` (if
  one was given). Output is appended to the existing NetCDF files.
- The log ends with "Reached stop time …" or "Wall-time limit reached … Continue with --restart".

**GPU startup.** The precompiled code covers the CPU side. GPU jobs compile their GPU-specific
code (Float32 methods and CUDA kernels) at startup, which takes a few minutes and is part of
the 1 h margin between `WALL_TIME` and `--time`.

## Writing a new experiment

Copy `monsoon_convection.jl` and edit only the driver. Its comments show where each piece goes.

- **Sounding.** Read a CM1-format file, or write profiles as anonymous functions of height and
  *evaluate* them on a vector of heights:

  ```julia
  sounding = read_cm1_sounding("path/to/input_sounding")       # CM1 isnd = 7 format
  z = collect(0.0:100.0:40000.0)
  θ = z -> 300 + 4e-3z;  r = z -> 0.018exp(-z / 2500);  u = z -> -5.0;  v = z -> 0.0
  sounding = Sounding(101000.0, z, θ.(z), r.(z), u.(z), v.(z))  # r = vapor MIXING RATIO (kg/kg)
  ```

- **Grid and physical parameters** are keyword values of `build_model`, e.g.
  `build_model(sounding; arch, Nx, Ny, Δx = 250, sea_surface_temperature = 302, CO₂ = 420e-6)`.
  Pass `z_faces` as a `Vector` (`collect(...)`), not a range.

- **Initial conditions.** Use `set_initial_conditions!(model, sounding)` (CM1 `irandp = 1`), or
  `set!` with functions of `(x, y, z)`. `set!` expects:
  - `θ`: liquid-ice potential temperature
  - `qᵗ`: total-water **specific humidity**, qᵗ = r / (1 + r)
  - `u`, `v`

None of these recompile the package. Changing a physics *scheme* is done in the "Model"
section of `MonsoonConvection/src/MonsoonConvection.jl` and does recompile.

## Glossary

- **Precompilation**: Julia compiles a package ahead of time and stores the result (a
  *package image*, or "pkgimage") in the depot, so later sessions load compiled code instead
  of compiling it.
- **Warm-up run** (PrecompileTools "workload"): a short model run executed *during*
  precompilation so that the code it exercises is compiled and cached. It is about which code
  gets cached, not about hardware.
- **Compile cache / depot**: where precompiled packages live (`~/.julia` by default;
  `JULIA_DEPOT_PATH` to change). Caches are specific to the Julia version, package versions,
  CPU type and preferences.
- **Preference** (`LocalPreferences.toml`): a per-machine setting read at compile time, e.g.
  CUDA's pinned runtime version.
- **CUDA context**: the per-process state CUDA creates on the GPU at the first GPU operation.
  Creating it fails if the GPU is busy or not allocated to you.
- **Checkpoint**: a file with the full model state, used to restart a run.

## Troubleshooting

These are the failures met while setting up the cluster, with causes and fixes:

- **"GPU requested, but no NVIDIA GPU was found"**: you're on a node without a GPU (e.g. the
  login node). Move to a GPU allocation (`srun ... --gres=gpu:1`) or use `--arch=cpu`. Nothing
  was changed.
- **"CUDA.functional() is false"** (or "CUDA.jl could not find an appropriate CUDA runtime"): CUDA's
  runtime package was compiled on a node without a driver (the login node) and recorded "no
  runtime". Pin the runtime version on the GPU node as `check_gpu.jl` instructs. Avoid it in
  future by never precompiling on the login node; install there with
  `JULIA_PKG_PRECOMPILE_AUTO=0 julia --project -e 'using Pkg; Pkg.instantiate()'`.
- **"Out of GPU memory" while creating a context** (stack trace through
  `cuDevicePrimaryCtxRetain`), even for a tiny model: the GPU is in use by another process, or
  your shell has no GPU allocated. Check `echo $SLURM_JOB_GPUS $CUDA_VISIBLE_DEVICES` (empty
  means no allocation), `nvidia-smi` (other processes, memory use) and
  `ps -u $USER -f | grep julia` (leftover sessions). Start a fresh `srun ... --gres=gpu:1`.
- **LLVM "out of memory" or `ProcessSignaled(9)` while precompiling**: not enough memory for
  the precompile, which needs about 6 GB. Login nodes usually allow less, and a multi-target
  `JULIA_CPU_TARGET` multiplies the need. Precompile on a compute node with `--mem=32G`, and
  leave `JULIA_CPU_TARGET` unset.
- **CUDA out of memory during a full-size run** (not at context creation): the GPU is too small
  for the full domain (≈ 17 GiB of model state). Request a larger GPU type, or reduce `Nx`,
  `Ny` in the driver.
- **"Precompiling MonsoonConvection" appears on every run**: check that `JULIA_CPU_TARGET`
  and `JULIA_DEPOT_PATH` are identical at precompile time and run time, and that nothing
  edits `MonsoonConvection/src`.
- **Leftover `[MonsoonConvection] precompile_gpu` in `LocalPreferences.toml`**: from an earlier
  version; nothing reads it now. Delete that section, and keep the `CUDA_Runtime_jll` entry.
- **NetCDF "already exists … Mode will be set to append"** on `--restart`: expected; output
  continues in the same files.
- **`test_checkpoint.jl`** needs CairoMakie and UnicodePlots, which aren't in this
  environment. Run it with its own environment.
