# Switching from P3 to single-moment microphysics (2026-10-11)

P3 in Breeze is not production ready, and the NaN at ~17.5 h (`nan_investigation.md`) first shows
up in the P3 ice number. This note covers switching to single-moment microphysics. Nothing has been
changed yet.

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
- **Where to change it:** `MonsoonConvection/src/MonsoonConvection.jl:310`
  (`microphysics = on_architecture(arch, P3Microphysics())`). Changing the scheme type forces a
  full recompile (comment at line 183).
- **Other code to update:**
  - Initial conditions: the P3 fields (`qi`, `qf`, `qwi`, ice number) have to map onto 1M cloud ice
    and snow. The CM1 case uses ptype = 5 (`monsoon_convection.jl:15`).
  - `--debug_nan` diagnostics and `sedimentation_rate_profile` in `monsoon_convection.jl`
    (~lines 272–315) read P3 microphysical fields.
  - Output field lists that name P3 fields.
  - Restarts from P3 checkpoints (e.g. iteration 7699) won't carry over. A 1M run starts from t = 0.
- **The sedimentation problem doesn't go away.** One-moment rain and snow still fall through the
  50 m bottom cell, so keep `--sedimentation_cfl`. One-moment does remove the P3 ice-number blow-up
  that `adv_bounded` hit first.

## Plan

1. Wait for `sed_cfl` and `conv_64` (`STATUS.md`). If `sed_cfl` gets past iteration 7934, the P3
   run can continue while the 1M version is set up alongside it.
2. Add the one-moment option behind a flag (e.g. `--one_moment`), so P3 stays available.
3. Test on CPU with `--small_test`, then run the full case on `aerosmith`.
