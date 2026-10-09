# Status (updated 2026-10-09)

Read this first when picking the work back up. Details: `nan_investigation.md` (what failed and
why), `breeze_internals.md` (what we learned in the Breeze/Oceananigans source), `workflow.md`
(commands and conventions).

## Goal

The CM1 EKAMSAT monsoon-convection case in Breeze.jl: 1024×512×58, Δx = 500 m, 28 km lid, P3,
RRTMGP, 4 days on one A100 (`aerosmith`, partition `ceoas-gpu`).

## Where it stands

- Mixed precision (Float32 model + Float64 pressure solve) is the GPU default. It's stable at the
  top. It **fails with NaN at the onset of deep convection, ~17.5 h (iteration ~7930–8000)**, with
  either bounded or unbounded advection.
- Leading suspect: **sedimentation Courant number > 1** in the 50 m lowest cell (Breeze's Δt
  ignores fall speeds). The `--sedimentation_cfl` fix exists and works in a CPU test; it hasn't
  been tried on the full run yet.

## Runs on the cluster (`/ceoas/deszoeks/projects/monsoon-breeze/run/`)

| Run | Setup | Result |
|---|---|---|
| (≥ 2 earlier runs) | mixed precision, unbounded advection | NaN ~iteration 8000 (17.5 h) |
| `adv_bounded` (job 5751294) | restart from 7699, bounded advection, `--debug_nan` | NaN at 7934; ice number first, from k = 1 up |
| `conv_64` | all-Float64 | still running at last check |
| `sed_cfl` (submitted 2026-10-09) | restart from 7699 + `--sedimentation_cfl --debug_nan` | running |

## Next steps

1. Check `sed_cfl` (submitted, precompiled): does it pass iteration 7934? Watch Δt (~3–4 s in
   heavy precipitation) and the "max sedimentation Courant number" line (≤ ~0.7).
2. Code graphs of Breeze/Oceananigans for analysis: `helpers/graph_package.sh` (see CLAUDE.md).
3. Compare with `conv_64`: whether Float64 also fails at ~17.5 h tells whether precision matters.
4. Optional: draft a Breeze issue saying AIVA leaves out the fall speeds on the anelastic path
   (`breeze_internals.md`). With that fixed, AIVA would be a cheaper fix than `--sedimentation_cfl`.
5. Drafts not yet filed: `breeze_issue_p3_gpu.md`, `breeze_issue_pressure_precision.md`.
