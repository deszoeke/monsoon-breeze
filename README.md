# Monsoon convection in Breeze.jl

A Breeze.jl version of the CM1 (r21.1) EKAMSAT Arabian Sea monsoon-convection case in
`cm1/`: the 17 June 2023 sounding with a dry layer at 4800–7200 m and strong low-level shear,
adapted from CM1 `cpm_RadConvEquil`. The header of `monsoon_convection.jl` lists how each
CM1 namelist option maps to Breeze.

## Quick start

```sh
# laptop (CPU), once:
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project setup_precompile.jl --arch=cpu

# quick check that everything runs (16 km × 8 km domain, 1 simulated hour, ~3 min):
mkdir -p runs/small_test && cd runs/small_test
julia --project=../.. ../../monsoon_convection.jl --small_test
```

## Files

| File | Purpose |
|---|---|
| `monsoon_convection.jl` | Experiment driver: sounding, initial conditions, grid size, run settings. Edit freely. |
| `MonsoonConvection/` | Local package with the model setup, output and restart logic. Precompiled. |
| `MonsoonConvection/ext/MonsoonConvectionCUDAExt.jl` | GPU warm-up run for precompilation, used only with CUDA. |
| `setup_precompile.jl` | Requests the hardware to precompile for (`--arch=cpu` or `--arch=gpu`), then precompiles. |
| `monsoon_job.sh` | Slurm batch script for GPU runs on partition `ceoas-gpu` (submit from the run directory). |
| `preflight.jl` | Command-line parsing and the quick hardware check, run before any package loads. |
| `Project.toml`, `Manifest.toml` | Julia environment with pinned package versions. |
| `LocalPreferences.toml` | Created by `setup_precompile.jl --arch=gpu`; records the GPU precompile request. |
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
| `--float=Float32\|Float64` | Float32 on GPU, Float64 on CPU | Floating-point precision. Single precision is standard for GPU runs of this kind; the precompile warm-up covers only these defaults. |
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

Julia compiles code the first time it runs. For this model that used to cost about 2.5 min of
every run before the first useful time step. The setup avoids that as follows.

1. **Precompiled package.** All model and simulation setup lives in the package
   `MonsoonConvection`. During precompilation it executes a short **warm-up run**: a 32×16×65
   model that takes 3 steps, writes output and a checkpoint, and restarts from it. Julia
   caches the compiled code for everything the warm-up touches.
2. **Experiments are values, not code.** Compiled code depends on the *types* of the inputs,
   not their *values*. The sounding is passed as plain vectors (`Sounding`), and the
   geostrophic wind is read from a precomputed field. Changing the sounding (values or number
   of levels), initial conditions, grid size or parameter values therefore reuses the cache.
3. **Hardware is requested, never auto-detected.** You request `--arch=cpu` or `--arch=gpu`.
   A quick check runs before anything could touch the compile cache, and halts with no
   changes if the hardware is missing. CUDA is loaded only for `gpu`.
4. **GPU warm-up is isolated.** The GPU warm-up lives in a package extension controlled by
   the `precompile_gpu` preference in `LocalPreferences.toml`. Switching between `cpu` and
   `gpu` recompiles only that extension, never the CPU cache. `setup_precompile.jl` writes
   the preference only when the request changes it.

### What triggers recompilation

| Change | Recompile? |
|---|---|
| Sounding values or levels, initial conditions, perturbations | No |
| Grid size, parameter values passed to `build_model` / `build_simulation`, run flags | No (a full-size grid compiles a few extra kernels at run time) |
| Editing `MonsoonConvection/src`, even comments | Yes, the package (≈ 2 min) |
| Microphysics or turbulence-closure *type*, new forcing kinds (edits in the package) | Yes, the package |
| `setup_precompile.jl` with a different `--arch` | Yes, only the CUDA extension |
| Package updates (`Pkg.update`) or a new Julia version | Yes |
| A different CPU type (laptop vs. HPC node) | Separate cache per CPU type (see HPC setup) |

After any change that recompiles, run `setup_precompile.jl` again before production runs.
Otherwise the first run pays the compile time itself.

## PC / laptop setup (CPU)

Tested with Julia 1.13.1 on an Apple M3.

```sh
cd /path/to/breeze
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project setup_precompile.jl --arch=cpu    # about 2.5 min once; seconds when nothing changed
```

The first run of a fresh install also downloads the radiation and microphysics lookup tables,
once per Julia depot.

```sh
mkdir -p runs/small_test && cd runs/small_test
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
- **No internet on compute nodes?** Then do the first precompile (step 2a) on a login node. It
  downloads the radiation and microphysics lookup tables. CUDA.jl's own runtime libraries are
  normally fetched when CUDA is first loaded; if that fails on a compute node, see the CUDA.jl
  documentation on `CUDA.set_runtime_version!`.

### 1. Environment and Julia depot (login node)

```sh
git clone git@github.com:deszoeke/monsoon-breeze.git ~/monsoon-breeze
cd ~/monsoon-breeze
export JULIA_DEPOT_PATH=/path/to/shared/julia_depot   # optional; put this in ~/.bashrc
julia --project -e 'using Pkg; Pkg.instantiate()'    # downloads the pinned package versions
```

Use the same Julia version as `Manifest.toml` (1.13.x); juliaup makes this easy.

**CPU type.** Compile caches are keyed by CPU type. If the login node and the `ceoas-gpu` nodes
have different CPUs (compare `lscpu` output) but share the depot, set a multi-target
`JULIA_CPU_TARGET` in `~/.bashrc` *before* precompiling, so one cache serves both. Adjust the
targets to the CPUs you found:

```sh
export JULIA_CPU_TARGET="generic;skylake-avx512,clone_all;znver3,clone_all"
```

Otherwise, always precompile on a `ceoas-gpu` node.

### 2. Precompile

a) Optional, on the login node, which also downloads the lookup tables:

```sh
julia --project setup_precompile.jl --arch=cpu
```

b) On a GPU node, in an interactive session:

```sh
srun -p ceoas-gpu --gres=gpu:1 --cpus-per-task=4 --mem=32G --time=1:00:00 --pty bash -l
cd ~/monsoon-breeze
nvidia-smi                                         # confirm the GPU is visible
julia --project setup_precompile.jl --arch=gpu
```

- The first time it reports `precompile_gpu: true (changed)` and runs the CPU and GPU (Float32)
  warm-ups.
- Later runs report `unchanged` and finish in seconds.
- On a node without a working GPU it stops with an error and changes nothing.
- To go back to CPU-only precompilation, run `setup_precompile.jl --arch=cpu`. This rebuilds
  only the CUDA extension.

### 3. First GPU test (interactive)

In the same `srun` session, check that the GPU path works and measure throughput:

```sh
mkdir -p /path/to/scratch/monsoon_gputest && cd /path/to/scratch/monsoon_gputest
julia --project=$HOME/monsoon-breeze $HOME/monsoon-breeze/monsoon_convection.jl --arch=gpu --small_test
# full domain for 1 simulated hour: check memory (nvidia-smi in a second shell) and s/step
julia --project=$HOME/monsoon-breeze $HOME/monsoon-breeze/monsoon_convection.jl --arch=gpu --stop_time=1h 2>&1 | tee gpu_1h.log
```

The progress lines show the wall time per 100 steps. Multiply by the expected number of steps
(25,000–45,000) to estimate the length of the full run.

### 4. Production runs (batch)

Use the job script [`monsoon_job.sh`](monsoon_job.sh) in the repository. Submit it **from the
run directory** (one per experiment). Output, checkpoints and the Slurm log `slurm-<jobid>.out`
are written there:

```sh
mkdir -p /path/to/scratch/monsoon_run1 && cd /path/to/scratch/monsoon_run1
sbatch ~/monsoon-breeze/monsoon_job.sh              # first job
sbatch ~/monsoon-breeze/monsoon_job.sh --restart    # each continuation job, until the stop time
# or chain a continuation behind the first job:
jid=$(sbatch --parsable ~/monsoon-breeze/monsoon_job.sh)
sbatch --dependency=afterok:$jid ~/monsoon-breeze/monsoon_job.sh --restart
```

What the script does:
- Requests `-p ceoas-gpu`, 1 GPU, 4 CPUs, 64 GB of host memory and 48 h. Edit the `#SBATCH`
  lines to match step 0, or override at submission, e.g. `sbatch --time=24:00:00 ...` with
  `WALL_TIME=23h`.
- Runs `monsoon_convection.jl --arch=gpu --wall_time=$WALL_TIME` (default `47h`). Any
  arguments after the script name are passed through, e.g. `--restart` or `--stop_time=96h`.
- Assumes the repository is at `~/monsoon-breeze`; override with `REPO=/other/path sbatch ...`.
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

**What the cache does not cover on GPU.** The precompile cache covers the CPU-side work:
model construction, initialization, output setup and kernel launch code. The CUDA kernels
themselves are still compiled at the start of every GPU job, because CUDA.jl does not keep
them between sessions. Expect a shorter startup than without the package, but not the
near-zero startup seen on CPU.

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
- **Preference** (`LocalPreferences.toml`): a setting read at compile time. Changing it
  recompiles the code that reads it. Here only `precompile_gpu` exists.
- **Extension**: package code that loads only when another package (here CUDA) is loaded.
- **Checkpoint**: a file with the full model state, used to restart a run.

## Troubleshooting

- **"GPU requested, but no NVIDIA GPU was found"**: you're on a node without a GPU. Move to a
  GPU node or use `--arch=cpu`. Nothing was changed.
- **"precompile_gpu = true, but CUDA is not functional"** during precompilation: the GPU
  warm-up was requested, but `Pkg.precompile()` ran where CUDA doesn't work, e.g. a login
  node. Precompile on a GPU node, or run `setup_precompile.jl --arch=cpu`.
- **"Precompiling MonsoonConvection" appears on every run**: check that `JULIA_CPU_TARGET`
  and `JULIA_DEPOT_PATH` are identical at precompile time and run time, and that nothing
  edits `MonsoonConvection/src`.
- **CUDA out of memory**: the GPU is too small for the full domain (≈ 17 GiB of model state).
  Request a larger GPU type, or reduce `Nx`, `Ny` in the driver.
- **NetCDF "already exists … Mode will be set to append"** on `--restart`: expected; output
  continues in the same files.
- **`test_checkpoint.jl`** needs CairoMakie and UnicodePlots, which aren't in this
  environment. Run it with its own environment.
