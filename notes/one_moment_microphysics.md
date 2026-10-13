# Switching from P3 to single-moment microphysics (2026-10-11; implemented 2026-10-12)

P3 in Breeze is not production ready, and the NaN at ~17.5 h (`nan_investigation.md`) first shows
up in the P3 ice number. This note covers switching to single-moment microphysics.

**Implemented 2026-10-12:** `build_model(; microphysics = :one_moment)` (default) or `:p3`; driver
flag `--microphysics=one_moment|p3`. One-moment is mixed-phase non-equilibrium (MPNE1M, as in
Breeze's tests and the colleague's setup): prognostic `ρqᶜˡ, ρqᶜⁱ, ρqʳ, ρqˢⁿ`, fall speeds
`wᶜˡ, wᶜⁱ, wʳ, wˢⁿ`. `CloudMicrophysics` and `SpecialFunctions` are package dependencies (they load
Breeze's extension; the constructor comes from `Base.get_extension`). Only one-moment is in the
precompile workload; P3 compiles at startup. `--theta_sedimentation_fix` handles both schemes.
CPU-tested. GPU run `run/one-moment` (2026-10-12) passed 18.5 h with no NaN but has negative rain down to −3.4 g/kg (see `STATUS.md`). CPU warm-bubble test (32×16, 45 min, θ fix and sedimentation
CFL): deep cloud, max w 47 m/s, qcl 7.2, qci 2.2, qr 5.8, qsn 12 g/kg, no NaN; qr dips to
−1.7×10⁻³ g/kg despite bounded advection (watch in the full run). Breeze's mixed-phase one-moment has no negative-moisture
correction ("not yet implemented"), so keep bounded advection.

## Microphysics schemes Breeze offers (Breeze `SiwJe`)

| Scheme | Ice? | Usable here? |
|---|---|---|
| P3 (`P3Microphysics`, `src/Microphysics/PredictedParticleProperties/`) | yes | not production ready |
| **One-moment** (`OneMomentCloudMicrophysics`, `ext/BreezeCloudMicrophysicsExt/one_moment_microphysics.jl`) | **yes**, mixed-phase versions | **yes** |
| Two-moment (`TwoMomentCloudMicrophysics`, SB2006, `two_moment_microphysics.jl`) | no: warm phase only (`WarmPhaseNonEquilibrium2M`) | no |
| DCMIP2016 Kessler (`DCMIP2016KesslerMicrophysics`) | no: warm rain only | no |
| `SaturationAdjustment` alone | no rain or snow that falls out | no |

The one-moment scheme is the only option for deep convection with ice. It needs the
CloudMicrophysics extension, so `using CloudMicrophysics` has to be loaded.

The graphify graph of Breeze covers `src/` only, not `ext/`. Read the extension directly.

## Things to watch

- **The default has no ice.** `OneMomentCloudMicrophysics()` defaults to
  `cloud_formation = NonEquilibriumCloudFormation(nothing, nothing)`, and an ice setting of
  `nothing` means warm phase only. Ask for ice explicitly, with one of:
  - non-equilibrium: `NonEquilibriumCloudFormation(nothing, CloudIce())` (`MixedPhaseNonEquilibrium1M`)
  - saturation adjustment: `SaturationAdjustment(equilibrium = MixedPhaseEquilibrium())` (`MixedPhase1M`)
  - Constructor: `one_moment_microphysics.jl:160`. Mixed-phase type aliases: lines 421–437.
- **What had to change** (done): the microphysics choice (`microphysics_scheme` in
  `MonsoonConvection.jl`), `fall_speed_names` (adds `wᶜⁱ, wˢⁿ`), output long names, the `nⁱ` line
  in `--debug_nan`, and the θ fix's field lists. Initial conditions needed nothing:
  `set_initial_conditions!` sets only θ, qᵗ, u, v. Scalar bounds and outputs were already generic.
- Restarts from P3 checkpoints (e.g. iteration 7699) won't carry over. A 1M run starts from t = 0.
- **The sedimentation problem doesn't go away.** One-moment rain and snow still fall through the
  50 m bottom cell, so keep `--sedimentation_cfl`. One-moment does remove the P3 ice-number blow-up
  that `adv_bounded` hit first.
- **The θˡⁱ sedimentation leak** (`nan_investigation.md`) affects one-moment too.
  `--theta_sedimentation_fix` uses liquid ρqᶜˡ, ρqʳ and ice ρqᶜⁱ, ρqˢⁿ. Column check: a 2 g/kg rain
  layer gives −0.16 K s⁻¹ below it, a snow layer (0.9 m s⁻¹) −0.021 K s⁻¹ (sublimation latent heat).

## Plan

1. Last P3 test: `p3_fixes` (`STATUS.md`).
2. Then the full one-moment run on `aerosmith` from t = 0, with `--theta_sedimentation_fix
   --sedimentation_cfl --debug_nan --checkpoint_interval=1h`. Re-precompile on the cluster first.
