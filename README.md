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
mkdir -p run/small_test && cp monsoon_convection.jl run/small_test/
# in run/small_test/monsoon_convection.jl set  arch = :cpu  and  small_test = true, then
cd run/small_test && julia --project=../.. monsoon_convection.jl
```

## Files

| File | Purpose |
|---|---|
| `monsoon_convection.jl` | Experiment driver: sounding, initial conditions, grid size, run settings. Edit freely. |
| `MonsoonConvection/` | Local package with the model setup, output and restart logic. Precompiled. |
| `setup_precompile.jl` | Precompiles `MonsoonConvection` (CPU warm-up run) and checks that it loads. Same on every machine. |
| `precompile_job.sh` | Slurm batch job that runs `setup_precompile.jl` on a compute node with enough memory (the login node runs out); no GPU needed. |
| `check_gpu.jl` | Staged check that a GPU node can run the model (CUDA, GPU context, model steps on the GPU); `--smoke_test` adds a 10-min run, `--cpu` tests the script without a GPU. |
| `monsoon_job.sh` | Slurm batch script for GPU runs: `sbatch -p <partition> --gres=<gpu> monsoon_job.sh <run directory>`. |
| `helpers/preflight.jl` | Flag parsing and the GPU check used by the scripts above before any package loads; not run directly. |
| `helpers/pressure_solver_precision.jl` | Run-time override that gives the pressure solve its own precision (`pressure_solver_type`); a stopgap until Breeze offers this. |
| `Project.toml` | Julia environment. Package versions are bounded by the compat entries in `MonsoonConvection/Project.toml`; each machine keeps its own untracked `Manifest.toml`. |
| `LocalPreferences.toml` | Per-machine settings, e.g. the pinned CUDA runtime version on the cluster (git-ignored). |
| `run/` | Local run directory for output and checkpoints (git-ignored; created by the scripts). |
| `cm1/` | Original CM1 namelist, sounding and log. |

## Model domain and resources

| | Full run | `small_test = true` |
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
cell including halos in Float32 (the GPU default), twice that in Float64. This was measured with `Base.summarysize` at 32×16 and 64×64 and
extrapolated linearly:

| Configuration | Model state |
|---|---|
| Full run, Float32 model + Float64 pressure solve (GPU default) | **≈ 15 GiB**, plus a few GB of Float64 pressure-solve arrays |
| Full run, all Float64 | ≈ 30 GiB |
| `small_test`, Float32 (measured) | ≈ 54 MiB |

Allow headroom for the CUDA context and temporary arrays. In Float64 the full domain needs a GPU
with **at least 24 GB** in the default mixed precision, or 48 GB all-Float64; the A100 80 GB is
comfortable either way.

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
(see "First GPU test" below) to choose the job's `--time`.

## Changes to Breeze defaults

`MonsoonConvection` departs from Breeze's defaults or usual practice in the places below. Items 1,
2 and 4 are in `build_model`, item 5 in `build_simulation` (`MonsoonConvection/src/MonsoonConvection.jl`, "Model" section);
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
  `maximum(model.closure_fields.Kᵘ)` (also printed with `debug_nan = true`).
- **Changing it.** Pass a different value from the driver, which needs no recompile:
  `build_model(sounding; arch, Nx, Ny, maximum_diffusivity = 50)`. `Inf` restores Breeze's
  default.
- **Upstream.** Worth raising with the Breeze developers: a mixing-length limit (e.g. a Blackadar
  form ℓ = κz / (1 + κz / ℓ∞)) or finite default caps would prevent the runaway at its source.

### 2. Microphysics built on the target architecture (bug workaround, no physics change)

`microphysics = on_architecture(arch, ...)`. Breeze 0.11.3 and 0.12.0 embed the microphysics in
the surface-flux boundary conditions before moving it to the GPU, so P3 GPU runs failed with "not
isbits" (CPU lookup tables inside a GPU kernel). Building the microphysics on the GPU first avoids
that; on CPU it does nothing. Breeze issue #1051, fixed on main by PR #1076 (2026-10-14) but not
yet in a release.

The default microphysics is now Breeze's mixed-phase one-moment scheme (non-equilibrium cloud
liquid and cloud ice, rain, snow; from CloudMicrophysics.jl) rather than P3, which is not
production ready in Breeze. `microphysics = :p3` restores P3. See `notes/one_moment_microphysics.md`.

### Vertical grid above 18 km (driver)

The driver (`monsoon_convection.jl`, `stretched_top_faces`) keeps CM1's levels up to 18 km. Above
that, Δz increases linearly from 500 m to about 1 km at the 28 km lid: 58 levels instead of
CM1's 65. The tropopause region (cold point ~16–17 km) stays at 500 m. The coarser
stratosphere and sponge improve the conditioning of the pressure solve for the longest
horizontal waves (∝ Δz², ~4× at the top) and save ~11% of the cells. This is like Breeze's
TC-world RCE grid (1 km at a 28 km lid). Set `Δz_top` in the driver, or pass
`z_faces = MonsoonConvection.cm1_z_faces()` to `build_model` for CM1's original 65 levels.

### 3. Float64 pressure solve (numerical precision)

Breeze GPU examples run entirely in Float32. Here the **pressure solve always runs in Float64**
(`pressure_solver_type = Float64`, the default), because in Float32 it is unstable on the full
512 × 256 km domain. On GPU the rest of the model runs in Float32 (mixed precision, the default);
on CPU everything is Float64.

- **Symptom.** In Float32 the temperature in the top grid cell (27.5–28 km) develops a
  domain-scale pattern (wavelength ≈ the 512 km domain) that grows exponentially, by e-folds of
  ~100 s with the default w-only sponge. It becomes visible about 10–15 simulated minutes in.
  K then pins at the cap at 27.5 km, and the run ends in NaN in P3 ice number above 23 km
  (iteration ~240, ~16 min).
- **What it is not.** It is the same on CPU and GPU, and the same at 500 m and 4 km grid
  spacing on the full domain. It is absent on the 16 × 8 km test domain. A stronger sponge
  (`sponge_variables = :all`, `sponge_timescale = 60seconds`) only delays it, to ~1.7 h.
- **Float64 removes it.** Full domain on GPU at 500 m, 3 h: the top-cell spread stays below
  0.7 K, structure ~20 km, no cap, no NaN. The same holds on CPU at 4 km.
- **Cause: the Float32 anelastic pressure solve (confirmed).** A Float32 model with a Float64
  pressure solve is stable and matches all-Float64. A Float64 model with a Float32 pressure solve
  fails like all-Float32 (4 km test domain on CPU). The solve is poorly conditioned for the
  longest horizontal waves under a tall, strongly stratified column: roughly (k Δz)⁻² ≈ 3×10⁴ for
  a 512 km wave with Δz = 500 m, while Float32 keeps only ~7 digits. Breeze's TC-world RCE
  example (288 km, Δz = 1000 m at the top, about 13× better conditioned) runs in Float32. Draft
  issue: `breeze_issue_pressure_precision.md`.
- **Mixed precision (GPU default).** The model runs in Float32 with only the pressure solve in
  Float64 (`helpers/pressure_solver_precision.jl`). On the A100, full domain, it took 0.67 s per
  step against 1.3 s for all-Float64, about 2× faster. A 4-day run (~43,000 steps at Δt ≈ 8 s)
  takes about 8 h instead of 15 h. Through 1 h its diagnostics matched all-Float64 to the printed
  precision. It works by redefining Breeze's solver construction for the session (written
  against Breeze 0.11.3, checked on 0.12.0; it warns on other versions), so it's a stopgap until Breeze has such an
  option. All-Float64 remains available with `float_type = Float64`.

The `sponge_variables = :all` option (relax u, v, θ in the sponge layer, CM1 `irdamp = 1`) remains available,
but is not needed in Float64.

### 4. Bounded (positivity-preserving) WENO scalar advection

Every advected scalar uses `WENO(order=5, bounds=(min, max))` (`build_model`, keyword
`bounded_scalar_advection = true`; bounds in `MonsoonConvection.scalar_bounds`). Breeze's default
is unbounded WENO(5).

- **Why.** Unbounded WENO can undershoot below zero at sharp edges, such as updraft and cloud
  edges. Negative moisture, hydrometeor or number values can then make P3 produce NaN. The
  first full-domain mixed-precision run failed with NaN at 17.5 h, at the onset of deep
  convection. Breeze's TC-world RCE example, which runs strong convection in Float32, bounds its
  moisture the same way. In a forced-condensation test, unbounded advection gave cloud and rain
  minima of about −10⁻¹⁴; bounded advection keeps them at exactly 0. The physics is otherwise the
  same.
- **How.** Oceananigans' Zhang–Shu (2010) limiter (marked experimental) scales each cell's
  reconstructions toward the cell mean, so that advection keeps the **specific** value
  (kg/kg, K, per kg; Breeze divides by ρ) inside the bounds. Every field is named, because any
  field left out of the NamedTuple would fall back to second-order `Centered` advection.

  | Fields | Quantity | Bounds |
  |---|---|---|
  | `ρqᵛ`, `ρqᶜˡ`, `ρqʳ`, `ρqⁱ`, `ρqᶠ`, `ρqʷⁱ` | mass fractions | (0, 1) |
  | `ρnʳ`, `ρnⁱ` | number per kg | (0, 10²⁰) |
  | `ρbᶠ` | rime volume per kg (m³ kg⁻¹) | (0, 1) |
  | `ρe` | TKE (m² s⁻²) | (0, 10⁶) |
  | `ρθ` | liquid-ice potential temperature (K) | (150, 2000) |

  Upper bounds are physical maxima, chosen loose so they never clip real values. The limiter acts
  only where a reconstruction would leave the bounds.
- **Not a strict guarantee here.** The limiter is guaranteed only for total Courant number
  ≤ 5/18. We run at CFL 0.7, as Breeze's TC world does, which removes most undershoots but not
  provably all.
- **Sources must stay inside the bounds.** The limiter assumes the cell values are already
  inside the bounds, and sources (radiation, latent heating, microphysics) can push them out. The driver checks the
  specific range of every bounded field every 10 iterations. It warns (once per field; every
  time with `debug_nan = true`) if a field leaves its bounds, which means the limiter is unreliable
  there.
- **Comparing.** `bounded_advection = false` restores Breeze's unbounded WENO(5) for all scalars.

### 5. Fall speeds in the time-step limit (`sedimentation_cfl`, on by default)

P3 moves each hydrometeor field by adding its fall speed to w in that field's advection. Breeze's
time-step wizard limits Δt with u, v and w only, so the fall speed never constrains Δt, and
Breeze 0.11.3 has no sedimentation substepping. Its adaptive implicit vertical advection leaves out
the fall speeds on the anelastic path. Rain falls at up to ~9 m/s, and dense rimed ice at
10–20 m/s. In the 50 m lowest cell at Δt ≈ 8 s, the fall Courant number |w + w_fall| Δt / Δz
exceeds 1, and explicit WENO is unstable there.

- **Evidence.** In a forced-condensation test (small domain, CPU), rain alone reached a fall
  Courant number of 1.3–2.1 at Δt ≈ 8 s. The full-domain runs (mixed precision, bounded or
  unbounded advection) all failed at the onset of deep convection (~17.5 h, iteration
  ~7930–8000). Ice number went NaN first, from the lowest cell up, after max ice mass grew to
  5 g/kg.
- **Fix.** `sedimentation_cfl = true` (`build_simulation(...; sedimentation_cfl = true)`) also limits
  Δt so that the fall Courant number ≤ `cfl` (0.7). In the test, Δt fell from ~8 s to ~3.5–4 s
  while rain was present, so heavy precipitation costs roughly 2× more.
  `debug_nan = true` prints the maximum fall Courant number and its height every 10 iterations.
- **Better long-term fix (upstream).** Sedimentation substepping (as in CM1), or implicit
  sedimentation, would remove the cost.

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
| `stop_time` | `345700seconds` ≈ 96 h (CM1 `timax`); `1hour` with `small_test` | **Total** simulated time, counted from the start of the original run. |
| `checkpoint_interval` | `1hour` (`30minutes` with `small_test`) | Model time between restart files. Only the latest is kept, and none is written when a run ends in NaN. |
| `debug_nan` | `false` | Every iteration, check prognostic **and** diagnostic fields for NaN/Inf and stop at the first, listing each bad field (fewest bad points first: nearest the origin). Every 10 iterations, print field extremes and the location, height and T of each bounds violation. |
| **Model** | | |
| `float_type` | `Float32` | Precision of the model. |
| `microphysics` | `:one_moment` | Mixed-phase one-moment, or `:p3` (closest to CM1's `ptype = 5`, not production ready; compiles at startup). |
| `sponge_variables` | `:w` | Upper sponge above 20 km. `:w` damps only w (CM1 `irdamp = 2`); `:all` also relaxes u, v and θ toward the sounding (`irdamp = 1`). |
| `sponge_timescale` | `300seconds` (CM1 `rdalpha`) | Sponge damping time scale at the model top (sin² ramp from 20 km). |
| **Fixes to Breeze (keep on)** | | |
| `pressure_solver_type` | `Float64` | Precision of the pressure solve. A Float32 solve is unstable on the full 512 km domain (see "Changes to Breeze defaults", 3). |
| `implicit_rain_sink` | `true` with one-moment | Backward-Euler rain–snow collection sinks, which otherwise drive rain and snow negative (`helpers/implicit_rain_sink_correction.jl`, `breeze_issue_uncapped_collection_sinks.md`). |
| **Stability options** (on in every tested run; not yet tested off with the fixes) | | |
| `sedimentation_cfl` | `true` | Also limit Δt by the hydrometeor fall speeds, so that (w + fall speed) Δt / Δz ≤ 0.7 (see "Changes to Breeze defaults", 5). |
| `bounded_advection` | `true` | Bounds-preserving WENO for scalars; `false` gives Breeze's plain WENO(5) (see "Changes to Breeze defaults", 4). |

Durations use `Oceananigans.Units`: `30minutes`, `1hour`, `4days`. Under Slurm the run stops and
checkpoints 10 min before the job's time limit (it reads `SLURM_JOB_END_TIME`); there is no limit
otherwise.

### Run directory and output

Output and checkpoints are written to the run directory (where Julia runs), and `restart = true`
looks for checkpoints there.

| File | Content |
|---|---|
| `<prefix>_profiles.nc` | Horizontal means, averaged over each hour |
| `<prefix>_surface.nc` | Hourly snapshots at the lowest model level (z = 25 m) |
| `<prefix>_fields.nc` | 3D snapshots, daily (every 30 min with `small_test`) |
| `<prefix>_checkpoint_iteration<N>.jld2` | Restart file (Julia format); only the latest is kept |

`<prefix>` is `monsoon_convection`, or `monsoon_convection_small_test` with `small_test`.

The NetCDF files have plain-ASCII variable names, with `units` and `long_name` attributes:

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

They open directly in Python (`xarray.open_dataset`), MATLAB (`ncread`), ncview, etc.

### Restarts

- A checkpoint is written every `checkpoint_interval` of model time, and whenever a run ends,
  at the stop time or 10 min before the Slurm job's time limit.
- `restart = true` resumes from the latest checkpoint in the run directory. Set it in the run's
  copy after the first job. The time step is recomputed from the CFL condition.
- `stop_time` is the **total** simulated time, not additional time. A run checkpointed at 24 h
  with `stop_time = 48hours` runs 24 more hours.
- On restart, output is **appended** to the existing NetCDF files.

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
5. **Hardware is requested, never auto-detected.** `arch = :cpu | :gpu`. A quick check halts a
   `:gpu` request before any package loads if no working GPU is present. CUDA is loaded only
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
mkdir -p run/small_test && cp monsoon_convection.jl run/small_test/
# in run/small_test/monsoon_convection.jl set  arch = :cpu  and  small_test = true, then
cd run/small_test && julia --project=../.. monsoon_convection.jl     # 1 h
# then set  restart = true  and  stop_time = 1.5hour  in the copy, and run it again
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

Use Julia 1.13.x on every machine; juliaup makes this easy. Without a tracked manifest, `Pkg.instantiate` resolves one from the compat bounds.

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
mkdir -p run/gpu_1h && cp monsoon_convection.jl run/gpu_1h/   # set stop_time = 1hour in the copy
cd run/gpu_1h && julia --project=../.. monsoon_convection.jl 2>&1 | tee gpu_1h.log
```

This runs the full domain for one simulated hour. Watch memory with `nvidia-smi` in a second
shell. The progress lines show wall time per 100 steps; multiply by the expected number of
steps (25,000–45,000) to estimate the length of the full run.

### 4. Production runs (batch)

Make the run directory with its copy of the driver, edit the copy's settings, then submit
[`monsoon_job.sh`](monsoon_job.sh) from the **repository directory** on the **login node**. The
script takes only the run directory; the partition and GPU go on the `sbatch` line. Its header
lists the partitions and working `sbatch` and `srun` lines.

```sh
cd /ceoas/deszoeks/projects/monsoon-breeze
mkdir -p run/exp && cp monsoon_convection.jl run/exp/          # edit run/exp/monsoon_convection.jl
sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp   # GH200 (aarch64), 96 GB GPU
sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh run/exp          # A100 (x86_64), 80 GB
# continue: set restart = true in run/exp/monsoon_convection.jl, then submit again
```

The script:
- requests 2 CPUs, 32 GB and 2 h. For long runs pass `--time`, e.g. `sbatch --time=48:00:00 ...`;
- sources [`helpers/arch_env.sh`](helpers/arch_env.sh), which sets Julia and Slurm up for the
  node's architecture (`uname -m`):
  - juliaup's Julia 1.13, not the system `julia`, which is 1.10;
  - that architecture's Julia depot, `JULIA_CPU_TARGET` and Slurm commands;
  - it removes the other architectures' directories from `PATH`.

  Add `source /ceoas/deszoeks/projects/monsoon-breeze/helpers/arch_env.sh` to `~/.bashrc` so
  login and interactive shells match;
- stops at once if the allocated GPU has less than 40 GB free;
- writes the log to `<run directory>/slurm-<jobid>.out`. The log starts with the node, GPU,
  Julia version and the copy's settings, and ends with "Reached stop time …" or "Wall-time limit
  reached …".

Notes:
- **Avoid `ceoas-arm-lowprio`.** A preempted job is requeued and reruns the copy as it is, from
  t = 0 unless `restart = true` is already set there.
- **Chained continuations** (`sbatch --dependency=afterok:$jid ...`) read the copy when they
  start, so set `restart = true` before the first job finishes.
- **The run stops 10 min before the job's time limit** and writes a checkpoint. That margin covers
  the final checkpoint; startup (compiling the GPU code, a few minutes) is inside the job's time.
- **Submit from the login node,** not from inside an interactive `srun` session, whose Slurm
  settings the job would inherit.

**GPU startup.** The precompiled code covers the CPU side. GPU jobs compile their GPU-specific
code (GPU-specific methods and CUDA kernels) at startup, which takes a few minutes and is part of
the job's time.

## Writing a new experiment

Copy `monsoon_convection.jl` and edit only the driver. Its comments show where each piece goes.

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
  login node). Move to a GPU allocation (`srun ... --gres=gpu:1`) or set `arch = :cpu`. Nothing
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
  temperature spread and max `Kᵘ` at the cap at 27.5 km** (`debug_nan = true`): the Float32
  instability on the full domain, from a Float32 pressure solve. Keep the default
  `pressure_solver_type = Float64` (check that the run's copy doesn't set Float32). See "Changes to
  Breeze defaults", 3.
- **CUDA out of memory during a full-size run** (not at context creation): the GPU is too small
  for the full domain (≈ 15 GiB in the default mixed precision, ≈ 30 GiB all-Float64). Request a larger GPU type, or reduce `Nx`,
  `Ny` in the driver.
- **"Precompiling MonsoonConvection" appears on every run**: check that `JULIA_CPU_TARGET`
  (`haswell,-rdrnd` in `~/.bashrc`) and `JULIA_DEPOT_PATH` are identical at
  precompile time and run time, and that nothing edits `MonsoonConvection/src`.
- **Leftover `[MonsoonConvection] precompile_gpu` in `LocalPreferences.toml`**: from an earlier
  version; nothing reads it now. Delete that section, and keep the `CUDA_Runtime_jll` entry.
- **NetCDF "already exists … Mode will be set to append"** on a restart: expected; output
  continues in the same files.
