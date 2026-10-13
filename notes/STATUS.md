# Status (updated 2026-10-12)

Read this first when picking the work back up. Details: `nan_investigation.md` (what failed and
why), `one_moment_microphysics.md` (the switch from P3), `breeze_internals.md` (what we learned in
the Breeze/Oceananigans source), `workflow.md` (commands and conventions).

## Goal

The CM1 EKAMSAT monsoon-convection case in Breeze.jl: 1024×512×58, Δx = 500 m, 28 km lid,
mixed-phase one-moment microphysics, RRTMGP, 4 days on one A100 (`aerosmith`, partition
`ceoas-gpu`).

## Current focus: the one-moment run (`run/one-moment`)

- Started from t = 0 on 2026-10-12, with
  `RUN=run/one-moment sbatch monsoon_job.sh --theta_sedimentation_fix --sedimentation_cfl --debug_nan --checkpoint_interval=1h`.
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
- **Fix: `--implicit_rain_sink` (`helpers/implicit_rain_sink_correction.jl`, 2026-10-12).**
  - A TendencyCallsite callback turns the rain sinks into backward-Euler: the cold-branch Sʳˢⁿ
    and Sᵃᶜᶜʳⁱ become S/(1 + Δt S/qʳ). The difference moves from snow back to rain, so water is
    conserved and θˡⁱ is unchanged.
  - Kernel check at the 63496 cell (Δt = 4 s, 272 K): one explicit step takes 2 / 0.5 / 0.1 g/kg
    of rain to −12.3 / −1.41 / −0.10 g/kg. The corrected step gives 0.25 / 0.10 / 0.033 g/kg,
    exactly qʳ/(1 + Δt/τ).
  - A 2-minute `--small_test` on the CPU runs. It had no rain yet, so the correction wasn't
    exercised in a model.
  - **Next:** restart one-moment from the latest checkpoint with `--implicit_rain_sink` and watch
    the ρqʳ and ρqˢⁿ minima in the bounds warnings.

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
- With `--debug_nan`, the bounds check warns every 10 iterations (otherwise once per field). The
  comment there wrongly says 100. Possible change: warn only on a new minimum, and print its
  location.

## Earlier runs (P3, abandoned) on the cluster (`/ceoas/deszoeks/projects/monsoon-breeze/run/`)

| Run | Setup | Result |
|---|---|---|
| (≥ 2 earlier runs) | mixed precision, unbounded advection | NaN ~iteration 8000 (17.5 h) |
| `adv_bounded` | restart from 7699, bounded advection, `--debug_nan` | NaN at 7934; ice number first |
| `conv_64` | all-Float64 | passed 8243 (2026-10-11); later status unknown |
| `p3_fixes` | restart from 7699 + θ fix + sedimentation CFL | NaN at 8326 (17.64 h), P3 ice number again |
| `sed_cfl` | restart from 7699 + `--sedimentation_cfl` | outcome unknown, superseded |

P3's ice number caused those failures, so P3 is dropped. It's still available with
`--microphysics=p3`.

## Other open items

- Drafts not yet filed: `breeze_issue_p3_gpu.md`, `breeze_issue_pressure_precision.md`,
  `breeze_issue_theta_sedimentation.md` (its workaround URL has a "…" placeholder).
- Optional Breeze issue: AIVA leaves out fall speeds on the anelastic path (`breeze_internals.md`).
- A colleague runs one-moment fully in Float32, including the pressure solve, on different
  levels. If ours stays stable, try `--pressure_solver=Float32`.
