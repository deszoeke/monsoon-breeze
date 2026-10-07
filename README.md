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
| `precompile_job.sh` | Slurm batch job that runs `setup_precompile.jl` on a compute node with enough memory (the login node runs out); no GPU needed. |
| `check_gpu.jl` | Staged check that a GPU node can run the model (CUDA, GPU context, model steps on the GPU); `--smoke_test` adds a 10-min run, `--cpu` tests the script without a GPU. |
| `monsoon_job.sh` | Slurm batch script for GPU runs on partition `ceoas-gpu`; output goes to `run/` by default. |
| `helpers/preflight.jl` | Flag parsing and the GPU check used by the scripts above before any package loads; not run directly. |
| `Project.toml`, `Manifest.toml` | Julia environment with pinned package versions. |
| `LocalPreferences.toml` | Per-machine settings, e.g. the pinned CUDA runtime version on the cluster (git-ignored). |
| `run/` | Local run directory for output and checkpoints (git-ignored; created by the scripts). |
| `cm1/` | Original CM1 namelist, sounding and log. |

## Model domain and resources

| | Full run | `--small_test` |
|---|---|---|
| Columns (Nx × Ny) | 1024 × 512 | 32 × 16 |
| Horizontal extent | 512 km × 256 km, Δx = Δy = 500 m | 16 km × 8 km |
| Vertical | 58 levels to 28 km: Δz = 50 m at the surface, stretching linearly to 500 m at 5 km, 500 m to 18 km (identical to CM1 `zf` so far), then stretching to ~1 km at the lid (CM1: 500 m to the top) | same |
| Grid cells | 30.4 million | 29,696 |
| Boundaries | periodic in x and y; rigid lid with a sponge above 20 km | same |
| Rotation | f-plane, f = 2.53 × 10⁻⁵ s⁻¹ (10°N) | same |
| Simulated time | 345,700 s ≈ 4 days (CM1 `timax`) | 1 h |
| Time step | adaptive, CFL 0.7, at most 15 s (≈ 8 s in the 1 h tests, before deep convection) | same |
| Time steps | roughly 25,000–45,000 | ≈ 570 |

**Memory.** The model plus simulation state takes about 111 3D arrays: about 444 bytes per grid
cell including halos in Float32, twice that in Float64 (the default). This was measured with `Base.summarysize` at 32×16 and 64×64 and
extrapolated linearly:

| Configuration | Model state |
|---|---|
| Full run, Float64 (default) | **≈ 30 GiB** of GPU memory |
| Full run, Float32 (unstable on this domain) | ≈ 17 GiB |
| `--small_test`, Float32 (measured) | ≈ 54 MiB |

Allow headroom for the CUDA context and temporary arrays. In Float64 the full domain needs a GPU
with **at least 48 GB**; the A100 80 GB is comfortable.

These are estimates; check them with `nvidia-smi` during the first GPU run. Host memory needs
are modest. Output is copied to the host before writing (≈ 2 GB per 3D snapshot), so 32–64 GB
of host RAM is ample.

**Disk** (estimates for the full run; one run directory per experiment):

| File | Size |
|---|---|
| `_fields.nc`: 14 variables × 30.4 M cells × 4 B per daily snapshot, 5 snapshots | ≈ 2 GB each, ≈ 10 GB total |
| `_surface.nc`: hourly, about 96 snapshots | ≈ 3 GB |
| `_profiles.nc` | < 10 MB |
| Checkpoint (JLD2, only the latest kept) | a few GB |

**Wall-clock time.** GPU throughput for this configuration hasn't been measured yet. On a
laptop CPU, the small test runs at about 0.27 s per step. Time a short full-size GPU run first
(see "First GPU test" below) to choose `--wall_time` and the job's `--time`.

## Changes to Breeze defaults

`MonsoonConvection` departs from Breeze's defaults or usual practice in the places below. Items 1
and 2 are in `build_model` (`MonsoonConvection/src/MonsoonConvection.jl`, "Model" section);
item 3 is the driver's default precision. Keep them in mind when interpreting results or comparing
with other Breeze runs.

### 1. TKE closure: eddy diffusivities capped at 100 m² s⁻¹ (safeguard; physics change only when active)

```julia
closure = TKEBasedTurbulenceClosure(; maximum_viscosity = maximum_diffusivity,
                                      maximum_tracer_diffusivity = maximum_diffusivity,
                                      maximum_tke_diffusivity = maximum_diffusivity)   # default 100 m² s⁻¹
```

- **Why.** Breeze's `TKEBasedTurbulenceClosure` (0.11.3) uses the mixing length
  ℓ = min(z, Cᴺ √e / N). Where the stratification is neutral or unstable (N² ≤ 0), ℓ falls back
  to z, the height above the ground. A locally unstable layer aloft therefore gets ℓ of order
  10–20 km, and K = Sᵘ ℓ √e of order 10⁴–10⁵ m² s⁻¹. Breeze's default caps are infinite.
- **What happened.** In the first full-domain GPU run, max Kᵘ jumped from ~40 to 3×10⁴ m² s⁻¹
  at iteration ~215, and the run failed with NaN at iteration 257. This turned out to be a
  **symptom** of the Float32 instability in item 3: the top cell became unstable and the closure
  responded with ℓ = z. In Float64 the cap never engages (max Kᵘ ≲ 50 m² s⁻¹, in the boundary
  layer). The cap stays as a safeguard against any unstable layer aloft.
- **Relation to CM1.** CM1's PBL scheme (`ipbl = 2`) limits the mixing length with
  `l_inf = 75 m` (namelist), which keeps K ≲ 50 m² s⁻¹ for typical TKE. The cap is the closest
  available substitute, since Breeze's closure has no mixing-length limit. It caps K, not ℓ, so it
  is not the same as CM1's formulation.
- **Effect.** It changes the physics only where K would exceed the cap. Normal maxima here are
  ~30–40 m² s⁻¹, in the boundary layer. Diagnose how often the cap is active by checking
  `maximum(model.closure_fields.Kᵘ)` (also printed by `--debug_nan`).
- **Changing it.** Pass a different value from the driver, which needs no recompile:
  `build_model(sounding; arch, Nx, Ny, maximum_diffusivity = 50)`. `Inf` restores Breeze's
  default.
- **Upstream.** Worth raising with the Breeze developers: a mixing-length limit (e.g. a Blackadar
  form ℓ = κz / (1 + κz / ℓ∞)) or finite default caps would prevent the runaway at its source.

### 2. P3 microphysics built on the target architecture (bug workaround, no physics change)

`microphysics = on_architecture(arch, P3Microphysics())`. Breeze 0.11.3 embeds the microphysics in
the surface-flux boundary conditions before moving it to the GPU, so GPU runs failed with "not
isbits" (CPU lookup tables inside a GPU kernel). Building P3 on the GPU first avoids that; on CPU
it does nothing. Draft issue report: `breeze_issue_p3_gpu.md`.

### Vertical grid above 18 km (driver)

The driver (`monsoon_convection.jl`, `stretched_top_faces`) keeps CM1's levels up to 18 km. Above
that, Δz increases linearly from 500 m to about 1 km at the 28 km lid: 58 levels instead of
CM1's 65. The tropopause region (cold point ~16–17 km) stays at 500 m. The coarser
stratosphere and sponge improve the conditioning of the pressure solve for the longest
horizontal waves (∝ Δz², ~4× at the top) and save ~11% of the cells. This is like Breeze's
TC-world RCE grid (1 km at a 28 km lid). Set `Δz_top` in the driver, or pass
`z_faces = MonsoonConvection.cm1_z_faces()` to `build_model` for CM1's original 65 levels.

### 3. Float64 by default, also on GPU (numerical precision)

Breeze GPU examples typically run in Float32. This case runs in **Float64** by default
(`--float=Float64`), because Float32 is unstable on the full 512 × 256 km domain:

- **Symptom.** In Float32 the temperature in the top grid cell (27.5–28 km) develops a
  domain-scale pattern (wavelength ≈ the 512 km domain) that grows exponentially, by e-folds of
  ~100 s with the default w-only sponge. It becomes visible about 10–15 simulated minutes in.
  K then pins at the cap at 27.5 km, and the run ends in NaN in P3 ice number above 23 km
  (iteration ~240, ~16 min).
- **What it is not.** It is the same on CPU and GPU, and the same at 500 m and 4 km grid
  spacing on the full domain. It is absent on the 16 × 8 km test domain. A stronger sponge
  (`--sponge=all --sponge_timescale=60s`) only delays it, to ~1.7 h.
- **Float64 removes it.** Full domain on GPU at 500 m, 3 h: the top-cell spread stays below
  0.7 K, structure ~20 km, no cap, no NaN. The same holds on CPU at 4 km.
- **Likely cause (not proven).** The anelastic pressure solve is poorly conditioned for the
  longest horizontal waves under a tall, strongly stratified column: roughly (k Δz)⁻² ≈ 3×10⁴ for
  a 512 km wave with Δz = 500 m. Float32 keeps only ~7 digits. Breeze's own TC-world RCE example
  (288 km, Δz = 1000 m at the top, about 13× better conditioned) runs in Float32.
- **Cost.** Twice the memory (≈ 30 GiB, see "Model domain and resources") and somewhat slower on
  GPU. A mixed-precision option (Float32 model, Float64 pressure solve) would be a candidate
  optimization, and an upstream suggestion for Breeze.

The `--sponge=all` option (relax u, v, θ in the sponge layer, CM1 `irdamp = 1`) remains available,
but is not needed in Float64.

## Running the model

```sh
julia --project=<path/to/breeze> <path/to/breeze>/monsoon_convection.jl [flags]
```

| Flag | Default | Meaning |
|---|---|---|
| `--arch=cpu\|gpu` | `cpu` | Hardware to run on. A `gpu` request is checked (NVIDIA device present, CUDA working) before any package loads; if unavailable the run stops immediately and nothing is changed. |
| `--float=Float32\|Float64` | Float64 | Floating-point precision. **Float32 is unstable on the full 512 km domain** (see "Changes to Breeze defaults", 3); use it only for small domains. |
| `--small_test` | off | 32×16 columns (16 km × 8 km), 1 h. A check that the code runs, not a scientific configuration. |
| `--restart` | off | Continue from the latest checkpoint in the current directory (see Restarts). |
| `--stop_time=96h` | 345700 s ≈ 96 h (CM1 `timax`); 1 h with `--small_test` | **Total** simulated time, counted from the start of the original run. Units: `d`, `h`, `min`, `s`. |
| `--wall_time=47h` | none | Real (wall-clock) time limit for this job. The run stops cleanly and writes a checkpoint. |
| `--sponge=w\|all` | `w` | Upper sponge above 20 km. `w` damps only w (CM1 `irdamp = 2`). `all` also relaxes u, v and θ toward the initial sounding (CM1 `irdamp = 1`). See Troubleshooting (instability under the lid). |
| `--sponge_timescale=300s` | 300 s (CM1 `rdalpha`) | Sponge damping time scale at the model top (sin² ramp from 20 km). |
| `--debug_nan` | off | Diagnostics: every iteration, check prognostic **and** diagnostic fields (temperature, P3, TKE diffusivities, radiative heating) for NaN/Inf; stop at the first, listing each bad field with its count and first grid location, fewest first. The field with the fewest bad points is nearest the origin. Prints field extremes every 10 iterations. |

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
6. **Compile on a compute node, with one portable CPU target.** On the cluster, precompile with
   `sbatch precompile_job.sh`, which gives the precompile enough memory. Because
   `JULIA_CPU_TARGET="haswell,-rdrnd"`, that cache works on every node type. The login node
   only does `git pull` and downloads packages.

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

**CPU type.** Compile caches are keyed by CPU type. Use the single portable target

```sh
export JULIA_CPU_TARGET="haswell,-rdrnd"     # in ~/.bashrc
```

so that one cache serves every node: the login node (AMD znver2), the A100 nodes (Intel
Sapphire Rapids) and the other GPU nodes. All of them support the Haswell instruction set.
Batch jobs and `srun` sessions inherit it from your shell. A job that sees a different
`JULIA_CPU_TARGET` rejects the cache and recompiles at startup. Avoid multi-target
strings (e.g. `"generic;sandybridge,clone_all;haswell,clone_all;…"`): they multiply the memory
needed to precompile. Five targets ran out of memory even on the login node's limit.

### 2. Set up and check a GPU node (interactive)

All compiling happens on a compute node, which has the NVIDIA driver and enough memory.
Precompiling needs about 6 GB, more than the login node allows.

**Precompile as a batch job** (simplest), from the repository directory on the login node:

```sh
cd /ceoas/deszoeks/projects/monsoon-breeze
sbatch precompile_job.sh          # no GPU needed, 32 GB, ≈ 5 min; log in slurm-precompile-<jobid>.out
```

The log ends with `Load check: ok`. Then check the GPU interactively:

```sh
srun -p ceoas-gpu --gres=gpu:1 --cpus-per-task=4 --mem=32G --time=1:00:00 --pty bash -l
cd ~/monsoon-breeze
nvidia-smi                                  # your GPU: ~0 MiB used, no other processes
echo $SLURM_JOB_GPUS $CUDA_VISIBLE_DEVICES  # set inside a GPU allocation

julia --project setup_precompile.jl         # (or this, if you skipped the batch job)
julia --project check_gpu.jl                # CUDA, GPU context, model compiles and steps on the GPU
julia --project check_gpu.jl --smoke_test   # once before production: adds a 10-min end-to-end run
```

`check_gpu.jl` prints PASS/FAIL per stage and stops at the first failure with the real error.

- **Stage 1 fails with "CUDA is not functional":** the message gives the fix, which is to pin
  the CUDA runtime to the driver's version, e.g.

  ```sh
  julia --project -e 'using CUDA; CUDA.set_runtime_version!(v"12.8")'   # version from nvidia-smi
  ```

  The pin is stored in `LocalPreferences.toml`, which is per machine and git-ignored.
- **Stage 2 fails, "the GPU is busy or not allocated to you":** see Troubleshooting ("Out of GPU
  memory" while creating a context).

Rerun the precompile (`sbatch precompile_job.sh`) and `check_gpu.jl` after every `git pull` that
changes `MonsoonConvection/src`, and after package updates.

### 3. Measure throughput (interactive, optional)

```sh
mkdir -p ~/monsoon-breeze/run/gpu_1h && cd ~/monsoon-breeze/run/gpu_1h
julia --project=$HOME/monsoon-breeze $HOME/monsoon-breeze/monsoon_convection.jl --arch=gpu --stop_time=1h 2>&1 | tee gpu_1h.log
```

This runs the full domain for one simulated hour. Watch memory with `nvidia-smi` in a second
shell. The progress lines show wall time per 100 steps; multiply by the expected number of
steps (25,000–45,000) to estimate the length of the full run.

### 4. Production runs (batch)

Submit [`monsoon_job.sh`](monsoon_job.sh) from the **repository directory** on the **login
node**. Arguments after the script name go to `monsoon_convection.jl`:

```sh
cd /ceoas/deszoeks/projects/monsoon-breeze
sbatch monsoon_job.sh                          # first job
sbatch monsoon_job.sh --restart                # each continuation, until the stop time
jid=$(sbatch --parsable monsoon_job.sh)        # or chain a continuation behind it:
sbatch --dependency=afterok:$jid monsoon_job.sh --restart
RUN=run/sst302 sbatch monsoon_job.sh           # another experiment in its own run directory
sbatch monsoon_job.sh --small_test --stop_time=10min   # quick test of the batch path
```

The script:
- requests one node of `ceoas-gpu` with A100s, 4 CPUs, 64 GB and 48 h;
- uses juliaup's Julia (`~/.juliaup/bin` first on `PATH`; the system `julia` is 1.10);
- runs on the first allocated GPU that's idle (see below);
- writes output and checkpoints to `RUN` (default `run/`, git-ignored) and the log to
  `slurm-<jobid>.out`. The log's first line gives the node, GPU, Julia version and run
  directory, and the last line says "Reached stop time …" or "Wall-time limit reached … Continue
  with --restart".

Notes:
- **A100 only.** `ceoas-gpu` also has GTX 1080 Ti nodes (e.g. ayaya05). Their 11 GB is too small
  for the full domain, and the CUDA 13 runtime no longer supports them.
- **Two GPUs requested, one used (temporary).** Slurm keeps assigning aerosmith's GPU 2, which
  another user's job is using without having requested a GPU. The script therefore asks for
  `gpu:a100:2` and runs on the idle one. It stops at once if all allocated GPUs are busy. Change
  it back to `gpu:a100:1` once GPU 2 is free.
- **Each experiment needs its own `RUN`.** A restart resumes from the latest checkpoint in `RUN`,
  and continuation jobs must use the same `RUN` and `--stop_time`. Output is appended to the
  existing NetCDF files.
- **Keep `WALL_TIME` (default 47h) about 1 h below `--time`.** That leaves time for startup
  (compiling the GPU code) and the final checkpoint. For example: `sbatch --time=24:00:00`
  with `WALL_TIME=23h`.
- **Submit from the login node,** not from inside an interactive `srun` session, whose Slurm
  settings the job would inherit.

**GPU startup.** The precompiled code covers the CPU side. GPU jobs compile their GPU-specific
code (GPU-specific methods and CUDA kernels) at startup, which takes a few minutes and is part of
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
- **"CUDA is not functional"** (or "CUDA.jl could not find an appropriate CUDA runtime"): CUDA's
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
  `JULIA_CPU_TARGET` multiplies the need. Precompile with `sbatch precompile_job.sh` (32 GB),
  and use the single target `JULIA_CPU_TARGET="haswell,-rdrnd"`.
- **NaN in P3 ice number above 23 km after ~15 min (or later), preceded by a growing top-cell
  temperature spread and max `Kᵘ` at the cap at 27.5 km** (`--debug_nan`): the Float32
  instability on the full domain. Run in Float64 (the default; check that `--float=Float32` isn't
  set). See "Changes to Breeze defaults", 3.
- **CUDA out of memory during a full-size run** (not at context creation): the GPU is too small
  for the full domain (≈ 30 GiB of model state in Float64). Request a larger GPU type, or reduce `Nx`,
  `Ny` in the driver.
- **"Precompiling MonsoonConvection" appears on every run**: check that `JULIA_CPU_TARGET`
  (`haswell,-rdrnd` in `~/.bashrc`) and `JULIA_DEPOT_PATH` are identical at
  precompile time and run time, and that nothing edits `MonsoonConvection/src`.
- **Leftover `[MonsoonConvection] precompile_gpu` in `LocalPreferences.toml`**: from an earlier
  version; nothing reads it now. Delete that section, and keep the `CUDA_Runtime_jll` entry.
- **NetCDF "already exists … Mode will be set to append"** on `--restart`: expected; output
  continues in the same files.
