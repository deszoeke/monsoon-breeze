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

## Tools added 2026-10-12

- `helpers/negative_condensate.jl` (committed and pushed). It runs on the CPU and reads a
  checkpoint directly, without building the model. Run it where the checkpoint is (aerosmith's
  login node is fine; no GPU or srun needed):
  `julia --project helpers/negative_condensate.jl run/one-moment/monsoon_convection_checkpoint_iteration8980.jld2`.
  - Prints, per condensate field: the minimum and its location, the negative-cell count, the
    negatives by level, and the column through the rain minimum.
  - Tested only on a fake checkpoint.
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
