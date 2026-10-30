# Status (updated 2026-10-30)

Read this first when picking the work back up. Details: `nan_investigation.md` (what failed and
why), `one_moment_microphysics.md` (the switch from P3), `breeze_internals.md` (what we learned in
the Breeze/Oceananigans source), `workflow.md` (commands and conventions), `cm1_migration.md` (the
CM1 case this began from).

## Goal

The CM1 EKAMSAT monsoon-convection case in Breeze.jl: 1024×512×58, Δx = 500 m, 28 km lid,
mixed-phase one-moment microphysics, RRTMGP, 4 days on one A100 (`aerosmith`, partition
`ceoas-gpu`).

## Control run `run/ekamsat-ctl0` (2026-10-28)

- GH200, Breeze 0.12.1 (our PR branch, includes upstream #1066). Failed twice with NaN at ~12 h
  (iteration ~4767), with and without `sedimentation_cfl`/`bounded_advection`: snow went to
  −2.3 g/kg at 5.25 km, then the whole column went NaN.
- Cause: `implicit_rain_sink` stacked on #1066's own limiter (`nan_investigation.md`). Restarted
  from the 11 h checkpoint with it off: past the failure, near 1 day (2026-10-28).
- `implicit_rain_sink` is retired: Breeze PR #1066 closed the issue (#1072) in 0.12.1, and the
  helper now warns and does nothing there.

## Driver cleanup (2026-10-28)

- `monsoon_convection.jl` 467 → 207 lines; the settings start on line 6, one line each, grouped
  Run / Domain / Sounding and surface / Model / Experiment / Fixes / Stability.
- New settings, formerly buried in the code: `Nx, Ny`, `Δz_top`, `sponge_bottom` (now passed to
  `build_model`), `δθ`, `seed`. `restart_checkpoint` takes `:latest` or another run's directory.
- `debug_nan` and the limiter-bounds check moved to `helpers/run_diagnostics.jl`
  (`add_nan_check!`, `add_limiter_bounds_check!`); log output unchanged.
- Usage text went to README; CM1 history from the driver and README went to `cm1_migration.md`;
  commented-out examples removed (README "Writing a new experiment" has them).
- Old run copies of the driver keep working; new runs need a fresh copy to get the new settings.

## Run plan (2026-10-28)

The run drivers are tracked in git (`run/*/monsoon_convection.jl`; the rest of `run/` is
ignored), all in the new driver format with `implicit_rain_sink = false`, `debug_nan = false`,
`sst_offset = 1.0`, `stop_time = 7days` unless noted.

1. **`ekamsat-ctl0`**, control spin-up, `stop_time = 2days`, `restart_checkpoint = :latest`.
   Its running job still reads the old driver (7 days): cancel it after an hourly checkpoint,
   `git pull` on the cluster (the new driver needs `helpers/run_diagnostics.jl`), resubmit; it
   resumes from its latest checkpoint and stops exactly at 2 days. Don't restart ctl0 after that.
2. **When ctl0 has stopped at 2 days**, submit the branches. Each has
   `restart_checkpoint = "../ekamsat-ctl0"`, which takes ctl0's *newest* checkpoint at the
   moment the job starts (ctl0 keeps only one), so they start from 2 days only if ctl0 has
   finished:
   - `ekamsat-ctl2`: control continuation, no source;
   - `ekamsat-moisten1000-850`, `-moisten850-650`, `-moisten650-440`: 1e-3 kg/kg/day vapor in
     (1000, 850), (850, 650), (650, 440) hPa.
3. **After each branch's first start**, set its `restart_checkpoint = :latest` before any
   resubmission; otherwise it restarts from ctl0's 2-day state again.

## P3 runs (2026-10-30)

The P3 tree is the current experiment; output goes to `run/ekamsat-p3-*` on the cluster.

- `ekamsat-p3-ctl0` finished at 2 days. Its driver now has `restart = true`; don't resubmit it.
- The four branches started from its 2-day checkpoint (GH200) and stopped at the 6 h wall limit,
  checkpointing 10 min before. They were resubmitted with a 12 h limit (`monsoon_job.sh`).
- All four resumed from their own checkpoints (`restart_checkpoint = :latest`).
- P3 output names differ from one-moment: `qcl qr nr qi ni qf bf qwi qv` (plus
  `surface_temperature`); no `qci`, `qsn`. `qi` is total ice, `qf` rime mass, `bf` rime volume,
  `qwi` liquid on ice, `n*` numbers per kg of moist air.

## P3 run plan (2026-10-29)

The experiment tree is redone with P3 microphysics (`microphysics = :p3`), on Breeze 0.13.

- **Why a new tree:** a P3 model can't restart from a one-moment checkpoint. Oceananigans 0.116
  restores by the checkpoint's field names, and the one-moment `ρqᶜⁱ`, `ρqˢⁿ` don't exist in P3
  (`FieldError: type NamedTuple has no field ρqᶜⁱ`, Mac test). P3 also needs `ρnʳ, ρqⁱ, ρnⁱ, ρqᶠ,
  ρbᶠ, ρqʷⁱ`, which the checkpoint lacks. Converting would need assumed particle sizes for the
  number concentrations; not done.
- **Drivers** (tracked): `run/ekamsat-p3-ctl0`, `-p3-ctl2`, `-p3-moisten1000-850`,
  `-p3-moisten850-650`, `-p3-moisten650-440`, copies of the one-moment drivers with
  `microphysics = :p3`; the branches have `restart_checkpoint = "../ekamsat-p3-ctl0"`.
- **Order**, as for the one-moment tree:
  1. `ekamsat-p3-ctl0` from rest (`restart = false`), 2 days. After its first start, set
     `restart = true` so resubmissions continue from its latest checkpoint.
  2. When p3-ctl0 has stopped at 2 days, submit the four branches (7 days), e.g. with
     `sbatch --dependency=afterok:<p3-ctl0 job id>`.
  3. After each branch's first start, set its `restart_checkpoint = :latest`.
- **Test** (Mac CPU, 2026-10-29): a P3 small-test control ran to 1 h, and a moistening branch
  restarted from its checkpoint (iteration 422) and ran to 2 h, no errors. The small test forms no
  condensate in 2 h (its 1 h state matches the one-moment run), so P3's processes are not yet
  exercised; the GPU small test and the first hours of p3-ctl0 are the real check. P3 is still
  marked "not production ready" in the driver.
- **Breeze 0.13 / Oceananigans 0.116.1** (registered; includes our PR #1105): the dev link to
  `../Breeze.jl` is removed from `Project.toml` `[sources]`; `MonsoonConvection/Project.toml`
  compat bounds only Breeze (`"0.13"`); Oceananigans and CloudMicrophysics follow Breeze's own
  bounds. One-moment small test passes on the Mac (max qᵛ 21.35 vs 20.97 g/kg on 0.12.1).
  Cluster: `git pull`, delete the root `Manifest.toml`, `Pkg.instantiate()` on each architecture.
  The one-moment ctl0 ran on 0.12.1; its branches will run 0.13 if submitted after the update.

## Plotting (2026-10-28, updated 2026-10-29)

- Everything is in `plots/`: `plotter.jl` (functions that read a run directory and return
  CairoMakie figures; including it only defines them), `plots.ipynb`, and its own environment
  (`plots/Project.toml`: CairoMakie, NCDatasets, JLD2, Revise, IJulia; no Breeze),
  `julia --project=plots -e 'using Pkg; Pkg.instantiate()'` once per machine.
- Notebook (run on the cluster, where the output is): `Pkg.activate`, `using Revise;
  includet("plotter.jl")`. No display: `julia --project=plots -e 'include("plots/plotter.jl");
  save_plots("run/ekamsat-ctl0")'` writes PNGs to `<run>/plots`.
- Readers: `read_profiles` (hourly-mean profiles, (z, time)), `read_snapshot` (`_fields.nc` 3D or
  `_surface.nc` lowest level), `read_checkpoint` + `checkpoint_snapshot` (latest state; ρᵣ(z)
  estimated as ⟨ρθ⟩/⟨θ⟩ since the checkpoint has no grid or ρᵣ).
- Plots: `plot_time_height` (T, qᵛ changes; cloud liquid, cloud ice, rain, snow in separate panels
  with the 0 °C level; radiative flux divergence), `plot_wind_time_height`, `plot_profiles`,
  `plot_xz`, `plot_xy`, `animate_surface` (hourly lowest level; 3D output is daily).
  `plot_*(f, ...)` plots a function of the variable, e.g. `log10`; `plot_axes(fig)` returns the
  axes for `xlims!`/`ylims!`. Font size 20 (`set_theme!`).
- `plotter.jl` was written for one-moment output (`qci`, `qsn`). The P3 runs need it to handle
  `qi`, `qf`, `qwi` and the numbers (plotting session).
- Used on the one-moment ctl0 (cluster notebook). Snow ~0.04 g/kg above 8 km: units checked (mass fraction
  ρqˢⁿ/ρᵣ, kg/kg moist air, plotted in g/kg); not a #1124 issue (that PR is θˡⁱ thermodynamics).
  Open: compare snow with cloud ice, and check for rain well above 0 °C.
- **Separate plotting session.** Plot iteration (color scales, axes, log scales, new panels) runs
  in its own Claude session, started in `plots/` (`claude --model sonnet`), with instructions in
  `plots/CLAUDE.md` (scope, data, conventions, notebook editing with `nb.py`). It owns `plots/`.
  Model, Breeze, run and physical-interpretation questions come back to the main session
  (repository root), which sends lookups to `code-reader`. The user routes between them; the
  sessions share only files and git, so pull and re-read before editing.

## Vapor-source experiments (planned 2026-10-27)

- Control sounding: `IdealizedSounding` (1010–10 hPa, 5 hPa levels put on heights hydrostatically
  in the driver; surface 1010 hPa). Initial wind = sounding wind. Geostrophic wind = sounding wind
  above 900 hPa (~1021 m), held at its 900 hPa value below. SST = lowest air T + `sst_offset`
  (1 K; may be too warm, as in CM1).
- Spin-up: the control runs 2 days with no source (`stop_time = 2days`). Each experiment branches
  from its 2-day checkpoint (`restart_checkpoint = "../ekamsat-ctl0"`, see "Run plan") with
  `vapor_source_rate` (kg/kg/day; vapor only, no heating; constant, horizontally uniform) in one
  `vapor_source_layer`: (1000, 850), (850, 650) or (650, 440) hPa. A new directory starts fresh
  NetCDF files at the restart time.
- Source rate 1e-3 kg/kg/day for the first set. CPU small tests passed (1 h, no NaN): the control sounding, the
  source (1e-3 kg/kg/day, 1010–850 hPa) with the SST offset (SST 303.8 K), and branching from
  another directory's checkpoint (`restart_checkpoint`).

## Breeze 0.12.0 (2026-10-14)

- Upgraded Breeze 0.11.3 → 0.12.0 and CloudMicrophysics 0.40.1 → 0.43.0 (compat in
  `MonsoonConvection/Project.toml`). 10-min `small_test` runs pass on the CPU for one-moment and P3.
- Breeze 0.12 (PR #959) corrects θˡⁱ for sedimentation itself, so `theta_sedimentation_fix` is
  gone from the driver. `helpers/theta_sedimentation_correction.jl` is now a no-op that warns, so an
  old run copy that still sets it runs without correcting twice (2026-10-15; it used to error).
- The collection-sink undershoot is fixed upstream in #1066 (merged 2026-10-22; in Breeze 0.12.1
  and our PR branch), which donor-limits the rain–snow rates. **With Breeze 0.12.1 set
  `implicit_rain_sink = false`**: the helper stacks on #1066 and caused the control's NaN at 12 h
  (off, the run passed 13.3 h; `nan_investigation.md`). On Breeze ≥ 0.12.1 the helper now warns
  and does nothing. With registered Breeze 0.12.0 it is still needed.
- `helpers/pressure_solver_precision.jl`: `dynamics_pressure_solver` is unchanged in 0.12.0.
- Precompiled on the cluster for x86_64 and aarch64 (each architecture's own depot). Old driver
  copies in run directories still run (the θ setting is ignored with a warning).
- Restarting from a 0.11.3 checkpoint should work: Breeze's checkpointing is unchanged and saves
  only named prognostic fields and the clock. Not yet tested; `run/breeze12` will be the test.
- **aerosmith GPU fault (2026-10-14, reported to admins):** Slurm prints "Failed to get device
  handle for GPU 3: Unknown Error" at every job start, and CUDA fails with error 999 at
  `cuDevicePrimaryCtxRetain` on the GPU it assigns (seen on GPU 2). `check_gpu.jl` fails at stage
  2. Until it is reset, run on `ceoas-arm`. `run/breeze12` is queued there, waiting for resources.
- To check: README "Changes to Breeze defaults" describes 0.11.3 behaviour (e.g. AIVA leaving out
  fall speeds, line ~218); #959 changed `implicit_advection_velocities`, so re-verify those notes.

## How runs are configured (since 2026-10-13)

- No command-line flags. Each run directory holds its own copy of `monsoon_convection.jl`, and the
  settings block at its top is the whole configuration. A queued job reads the copy when it
  starts, so editing the repository's driver never changes a submitted run.
- Submit: `sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/<exp>`. The header of
  `monsoon_job.sh` lists the partitions.
- Continue a run by setting `restart = true` in its copy.
- The wall time comes from `SLURM_JOB_END_TIME`: the run stops 10 min before the job's limit.
- On by default:
  - fixes: `pressure_solver_type = Float64`, `implicit_rain_sink`. The θˡⁱ sedimentation fix is
    built into Breeze 0.12 (PR #959), so our `theta_sedimentation_fix` setting is retired;
  - stability: `sedimentation_cfl`, `bounded_advection`, not yet tested off with the fixes;
  - `checkpoint_interval = 1hour`.
- **To do on the cluster:** copy the new driver into `run/one-moment`, set `restart = true` and
  `debug_nan = true`, then submit.

## Current focus: the one-moment run (`run/one-moment`)

- Started from t = 0 on 2026-10-12, with
  our θ sedimentation fix, `sedimentation_cfl` and `debug_nan` on and `checkpoint_interval = 1hour`.
  Mixed precision: Float32 model, Float64 pressure solve (the defaults).
- **Passed 18.5 h (iteration ~8680) with no NaN**, past every P3 failure (17.5–17.6 h). Checkpoint
  at iteration 8980 exists.
- **Open problem: negative rain.** The limiter-bounds warnings (our own check,
  `monsoon_convection.jl:372-401`) show, as specific values q = ρq/ρᵣ:
  - ρqʳ min −3.36 g/kg (max 4.3), almost unchanged from iteration 8660 to 8670. It looks like a
    stuck patch that nothing removes;
  - ρqˢⁿ min −0.19 → −0.05 g/kg, shrinking;
  - ρqᶜⁱ min −2×10⁻⁹, harmless.
  Breeze's mixed-phase one-moment scheme has no negative-moisture correction, and the WENO
  limiter is only guaranteed at Courant ≤ 5/18 (we run at CFL 0.7).
- **Next:** run `helpers/negative_condensate.jl` on the 8980 checkpoint (below), find where the
  negative rain is, then decide on a fix. The likely causes, and how the location tells them apart:
  - bottom 50 m cell: sedimentation outflow;
  - cloud top or the sponge: the advection limiter;
  - isolated points: a microphysics source.
  Possible fixes: clip negatives after the microphysics step (conserving water), or a smaller CFL.
- **Result at checkpoint 63496 (2026-10-12): the run is still alive and the negatives are small.**
  - ρqʳ: min −0.355 g/kg (max 3.73) in 13 cells, one per column, all at k = 18–20
    (4.3–5.25 km). That's the melting level, not the bottom cell and not cloud top. The domain-mean
    negative water is −3.75×10⁻⁷ kg m⁻². The −3.36 g/kg patch from ~8670 is gone.
  - ρqˢⁿ: min −0.0095 g/kg in 4 cells at k = 16–19, just below the snow's lower edge.
  - ρqᶜˡ and ρqᶜⁱ: round-off only.
  - In the column through the minimum (i, j = 294, 503), rain is negative (−0.355) at k = 19.
    Below it rain is 1.9–3.1 g/kg; above it rain is about 0. The same cell has 1.57 g/kg snow and
    1.43 g/kg cloud liquid, so it is saturated and evaporation can't be the cause.
  - Two candidates are left. Neither is decided.
    1. WENO sedimentation overshoot at the sharp rain top. The downward flux reconstructed at the
       k = 18|19 face draws on the large rain in k = 18.
    2. An unlimited rain–snow accretion or freezing sink at T < 0 °C.
  - To tell them apart: T at the minimum, and whether Breeze's sedimentation uses the bounded
    WENO.
- **What the code says (code-reader, 2026-10-12; installed Breeze/CloudMicrophysics):**
  - Sedimentation is not a separate flux. Each scalar is advected with w + w_fall through our
    bounded WENO5 (`MonsoonConvection.jl:337-343`), which keeps the specific q in (0, 1).
  - That bound holds only for Courant ≤ 5/18. Our wizard runs at CFL 0.7 of the tightest cell,
    usually the 50 m bottom cell.
  - `terminal_velocity` is 0 wherever q ≤ ε. No outflow cap.
  - Mixed-phase one-moment (`mpne1m_tendencies`, `ext/BreezeCloudMicrophysicsExt/one_moment_microphysics.jl:1119-1311`)
    is explicit, inside the RK stages.
    - Below Tᶠ = 273.15 K, rain is removed by Sʳˢⁿ (snow collects rain) and Sᵃᶜᶜʳⁱ (ice–rain).
      Both are uncapped and gated only by q > ε.
    - Evaporation and melt are capped at q/10 s. There is no rain-freezing term.
    - The only negative guard sets a negative species' microphysics tendency to −ρq/10 s and
      takes the water from a partner. There is no post-step clip.
    - `negative_moisture_correction` is not implemented for mixed phase (EXT:542).
  - Defaults throughout: E(rain–snow) = 1, E(ice–rain) = 1. The driver overrides nothing.
  - My assessment: an uncapped sink switches off as q → 0, so explicit overshoot from it should
    give only small negatives. −0.355 g/kg more likely comes from the bounded-WENO bound breaking
    at Courant > 5/18 at a sharp edge (rain top, snow bottom), possibly as the sum over x, y, z.
    Two things weren't read yet: how θ is computed in Oceananigans
    `bounds_preserving_tracer_advection_operators.jl`, and how the center-located wʳ reaches the
    z-faces.
  - **Superseded by the numbers below:** the cold rain–snow sink is stiff and does overshoot.
- **T and rain-loss timescale at the minimum (computed with Breeze's own functions, 2026-10-12).**
  The cell is (294, 503, 19), with ρᵣ = 0.7356 and pᵣ = 572.2 hPa.
  - T = 273.34 K (+0.19 °C) with the stored values, and 274.27 K with qʳ clipped to 0. The cell
    is just above Tᶠ = 273.15 K.
  - The timescale for snow (1.57 g/kg) collecting rain, Sʳˢⁿ in the cold branch with defaults:
    τ = 0.6 s at qʳ = 2 g/kg, 1.1 s at 0.5, 2 s at 0.1, 4.3 s at 0.01. Ice–rain τ is ≥ 11 s.
  - Δt is about 4 s, so Δt/τ is about 2–7. The explicit step overshoots badly: a forward-Euler
    step leaves qʳ(1 − Δt/τ).
  - Freezing rain into snow warms the cell by ℒf Δq/cᵖ at fixed θˡⁱ, about 0.33 K per g/kg. That
    can lift it above Tᶠ, where the sink switches off. This fits the cell sitting at +0.19 °C with
    negative rain and plenty of snow.
  - Hand check (`helpers/rain_snow_accretion_check.jl`): re-deriving the collection integral from
    the CloudMicrophysics parameters reproduces the code's rate exactly. **Not a code bug.**
  - It is 11–27× faster than Lin, Farley & Orville (1983) PSACR at the same q. Lin's τ is 6 s at
    2 g/kg rain and 32 s at 0.1 g/kg.
  - Most of the gap is the snow size distribution. ClimaParams gives n₀ˢⁿ = 4.36×10⁹ (ρqˢⁿ)^0.63,
    which is 3.1×10⁷ m⁻⁴ per diameter here, against Lin's fixed 3×10⁶. That means many more,
    smaller flakes (mean radius 0.46 mm). E(rain–snow) = 1 in both.
  - Even Lin's τ is about Δt at high rain, so any explicit, uncapped version of this process is
    marginal at Δt ≈ 4 s.
  - Literature (Consensus search):
    - Gaudet & Schmidt (2007, JAMC, doi:10.1175/jam2442.1) show the explicit bulk collection
      equation can deplete more than 100% of the collected species in one step, under plausible
      conditions. Schemes have to normalize or bound it.
    - Ferrier (1994, JAS) reformulates collection to avoid unrealistically large accretion rates.
    - Heymsfield et al. (2008, JAS) find exponential snow N₀ 5–30× larger than earlier
      assumptions (Lin's 3×10⁶). So the ClimaParams snow N₀ isn't unreasonable.
    - The fault is the missing cap, not the parameters.
- **Fix: `implicit_rain_sink` (`helpers/implicit_rain_sink_correction.jl`, 2026-10-12).**
  - A TendencyCallsite callback turns the rain sinks into backward-Euler: the cold-branch Sʳˢⁿ
    and Sᵃᶜᶜʳⁱ become S/(1 + Δt S/qʳ). The difference moves from snow back to rain, so water is
    conserved and θˡⁱ is unchanged.
  - Kernel check at the 63496 cell (Δt = 4 s, 272 K): one explicit step takes 2 / 0.5 / 0.1 g/kg
    of rain to −12.3 / −1.41 / −0.10 g/kg. The corrected step gives 0.25 / 0.10 / 0.033 g/kg,
    exactly qʳ/(1 + Δt/τ).
  - A 2-minute `small_test` on the CPU runs. It had no rain yet, so the correction wasn't
    exercised in a model.
- **First run with the fix (GH200 youmu, restart from 63496, iterations 63500–64170, 2026-10-13).**
  - The log from before the fix (iterations 63100–63490) had rain minima of −0.03 to −2.05 g/kg
    and snow minima of −0.002 to −0.04 g/kg.
  - **Rain is fixed.** 13 violations, all at 4–5 km. The worst is −0.0073 g/kg, about 300× smaller
    than before.
  - **Snow got worse.** 68 violations, 57 of them at 4–5 km and 56 with T ≥ 273.15 K. The worst is
    −0.34 g/kg at (461, 232, 19), T = 272.87 K.
  - Cloud ice: −5×10⁻⁹, round-off. No NaN.
  - Cause: the warm-branch mirror of the rain problem. Above Tᶠ, rain collecting snow (Sˢⁿʳ) plus
    the melt terms α(Sʳˢⁿ + Sᵃᶜᶜˡˢⁿ) remove snow explicitly, with no cap
    (`one_moment_microphysics.jl:1287-1292`). Keeping rain positive leaves more rain at the
    melting level, which feeds this sink.
- **Fix extended (2026-10-13).** `implicit_rain_sink` now also makes the warm snow sink
  backward-Euler. The correction moves Δ = δʳ − δˢⁿ from snow to rain.
  - Kernel check at Δt = 5 s, 274 K, 2 g/kg rain and 1.57 g/kg snow: an explicit step leaves snow
    at −0.147 g/kg, the corrected step at 1.21 g/kg. The cold cases are unchanged, and water is
    conserved exactly.
- **Second run, with the extended fix (GH200, iterations 64180–64780).**
  - Snow: worst −0.036 g/kg, 10× better than −0.34. 61 violations; 60 of them warm, 44 at 3–4 km,
    just below the melting level.
  - Rain: worst −0.018 g/kg. 36 violations, all at 4–5 km, at about Tᶠ.
  - Cloud ice: round-off. No NaN.
  - The negatives are now about 0.3–0.4% of each field's maximum.
  - The likely remainder: each sink is limited on its own, but not their sum. Snow melt (capped at
    qˢⁿ/10 s, about half the snow per 5 s step) plus the implicit collection sink can together
    exceed qˢⁿ where snow melts below the melting level. Cells crossing Tᶠ between RK stages could
    also contribute.
  - Judgment: small enough to carry on. A complete fix would limit each species' total sink to
    q/Δt, which is a Breeze-level change and could be reported upstream along with the uncapped
    collection sinks.
- **Log workflow:** don't paste raw logs. Paste the `helpers/log_summary.sh` output: the last
  progress line, NaN/errors, and per field the count, worst value, and where the extremes are by
  height and temperature.

## Tools added 2026-10-12

- `helpers/negative_condensate.jl` (committed and pushed). It runs on the CPU and reads a
  checkpoint directly, without building the model. Run it where the checkpoint is (aerosmith's
  login node is fine; no GPU or srun needed):
  `julia --project helpers/negative_condensate.jl run/one-moment/monsoon_convection_checkpoint_iteration8980.jld2`.
  - Prints, per condensate field: the minimum and its location, the negative-cell count, the
    negatives by level, and the column through the rain minimum.
  - Worked on the real checkpoint 63496.
  - It has a copy of the driver's `stretched_top_faces`; keep the two the same.
- Checkpoint layout (Oceananigans `Checkpointer`): `simulation/model/fields/<name>/data` is the
  CPU parent array **including halos** (H = 5); the clock is at `simulation/model/clock/{iteration,time}`.
- `monsoon_job.sh` runs Julia as `srun --unbuffered env CUDA_VISIBLE_DEVICES=$gpu ...`. Output
  reaches the log at once, and the idle GPU is chosen again inside the step. Not yet confirmed on a
  run: check that the log's GPU number matches what Julia uses.
- With `debug_nan`, the bounds check warns every 10 iterations (otherwise once per field). The
  comment is now fixed, and each violation prints its location, height and temperature.

## Grace Hopper (ARM) setup, 2026-10-13

- GH200 nodes (aarch64 Grace CPU with 480 GB, one 96 GB Hopper GPU each) are in partition `ceoas-arm` (rime, youmu).
  Avoid `ceoas-arm-lowprio`: it requeues preempted jobs with their first arguments.
- `monsoon_job.sh` names no hardware, so the partition and GPU go on the sbatch line:
  - `sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh ...` for an A100;
  - `sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh ...` for a GH200.
- `helpers/arch_env.sh` sets everything for the architecture `uname -m` reports: juliaup,
  `JULIAUP_DEPOT_PATH`, `JULIA_DEPOT_PATH`, `JULIA_CPU_TARGET` and the Slurm commands. It also
  removes the other architectures' directories from `PATH`.
  - x86_64 uses `~/.juliaup` and `~/.julia`, with `/local/cluster/slurm/bin`.
  - aarch64 uses `~/.juliaup-aarch64` and `~/.julia-aarch64`, with
    `/local/cluster/aarch64/slurm/bin`.
  - The job script sources it, and `~/.bashrc` should too.
  - Tested on both architectures, each with the other's settings leaked in: julia, srun and sbatch
    resolve correctly, and the precompiled caches stay valid.
- Julia 1.13.1 for aarch64 is installed, and the project is precompiled in `~/.julia-aarch64`
  (about 5 min on rime).
- CUDA runtime pinned to 12.9 in the cluster's `LocalPreferences.toml`, which is gitignored and
  shared by both architectures. The GH200 driver supports CUDA ≤ 12.9, and 13.2 failed there
  (job 5780041). The A100 driver runs 12.9 too. The 13.2 file is kept as
  `LocalPreferences.toml.bak-13.2`.
  - After the pin, precompiling passed `Load check: ok` on x86_64 (5780151) and aarch64 (5780152).
- Not yet tested: a model run on the GH200, or on the A100 with runtime 12.9.

## Earlier runs (P3, abandoned) on the cluster (`/ceoas/deszoeks/projects/monsoon-breeze/run/`)

| Run | Setup | Result |
|---|---|---|
| (≥ 2 earlier runs) | mixed precision, unbounded advection | NaN ~iteration 8000 (17.5 h) |
| `adv_bounded` | restart from 7699, bounded advection, `debug_nan` | NaN at 7934; ice number first |
| `conv_64` | all-Float64 | passed 8243 (2026-10-11); later status unknown |
| `p3_fixes` | restart from 7699 + θ fix + sedimentation CFL | NaN at 8326 (17.64 h), P3 ice number again |
| `sed_cfl` | restart from 7699 + `sedimentation_cfl` | outcome unknown, superseded |

P3's ice number caused those failures, so P3 is dropped. It's still available with
`microphysics = :p3`.

## Other open items

- Draft not yet filed: `breeze_issue_pressure_precision.md`.
- P3 on GPU: filed as Breeze #1051; fixed on main by PR #1076 (2026-10-14), not yet in a release
  (0.12.0 still has the bug). Keep our `on_architecture` workaround until a release includes it.
- Optional Breeze issue: AIVA leaves out fall speeds on the anelastic path (`breeze_internals.md`).
- A colleague runs one-moment fully in Float32, including the pressure solve, on different
  levels. If ours stays stable, try `pressure_solver_type = Float32`.
