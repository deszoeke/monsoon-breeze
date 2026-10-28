# CM1 → Breeze migration

How this project began as a Breeze.jl translation of a CM1 (r21.1) case, and where the Breeze
setup differs from CM1. Moved here from the header of `monsoon_convection.jl` and from README.md
(2026-10-28). The CM1 namelist, sounding and log are in `cm1/`.

## The CM1 case

ASdry4800-7200: EKAMSAT Arabian Sea monsoon convection, 17 June 2023 sounding, simplified with a
dry (qv = 0.3 g/kg) layer at 4800–7200 m and −8 m/s low-level shear. Adapted from the CM1
`cpm_RadConvEquil` case (Bretherton et al. 2005).

The default control is now the idealized sounding from `IdealizedSounding` (see STATUS.md); the
CM1 soundings remain available through `helpers/ekamsat_soundings.jl`.

## CM1 namelist → Breeze mapping

`build_model`'s keyword defaults are these CM1 values (see "Model" in
`MonsoonConvection/src/MonsoonConvection.jl`).

| CM1 | Breeze |
|---|---|
| nx, ny, nz = 1024, 512, 65; dx = dy = 500 m | RectilinearGrid, 512 km × 256 km |
| stretch_z = 1 (50 m → 500 m by 5 km), ztop 28 km | CM1 zf up to 18 km; above, Δz stretches to ~1 km at 28 km (**modified**; see "Vertical grid") |
| wbc = ebc = sbc = nbc = 1 | Periodic × Periodic |
| psolver = 3 (compressible) | AnelasticDynamics |
| hadvord/vadvord = 5, weno_order = 5 | WENO(order = 5) |
| ptype = 5 (Morrison 2-moment with ice) | mixed-phase one-moment microphysics (**modified**; `microphysics = :p3` for P3, the Morrison & Milbrandt successor, closest to ptype = 5 but not production ready) |
| ipbl = 2, sgsmodel = 0, horizturb = 0 (l_inf = 75 m) | vertical-only TKE closure, diffusivities capped at `maximum_diffusivity = 100` m²/s (**modified** from Breeze's default, no cap; see "TKE closure") |
| sfcmodel = 1, oceanmodel = 1, tsk0 = 301 K | bulk fluxes over a fixed SST (301 K for the CM1 case) |
| radopt = 2 (RRTMG), dtrad = 300 s, perpetual sun (solcon = 650.83 W/m², coszen = 0.636, albedo = 0.08, CO₂ = 387.75 ppm, from cm1.print.out) | RRTMGP all-sky, fixed cos(zenith), updated every 300 s |
| icor = 1, fcor = 2.5325e-5 (10°N) | FPlane(f = 2.5325e-5) |
| lspgrad = 1 | geostrophic forcing f × u_g(z) balancing the initial wind |
| irdamp = 2, zd = 20 km, rdalpha = 1/300 s | Rayleigh relaxation of ρw above 20 km, sin² ramp (`sponge_variables = :w`); `:all` also relaxes u, v, θ to the sounding (irdamp = 1) |
| isnd = 7 (input_sounding), irandp = 1 | sounding interpolated in z (`read_cm1_sounding`), ±0.25 K random θ perturbations (`set_initial_conditions!`) |
| timax = 345700 s (≈ 4 days), statfrq = 3600 s, tapfrq = rstfrq = 86400 s | `stop_time`, hourly mean profiles, daily 3D output and checkpoints |

Not translated: apmasscon, kdiv/alph acoustic damping (compressible only), CM1's
pressure-dependent microphysics options (nssl2mom_params are unused for ptype = 5).

## Vertical grid

The driver (`stretched_top_faces`) keeps CM1's levels (50 m at the surface stretching to 500 m by
5 km, then 500 m) up to 18 km. Above that, Δz increases linearly from 500 m to about 1 km at the
28 km lid: 58 levels instead of CM1's 65 (CM1 used 500 m to the top). The tropopause region (cold
point ~16–17 km) stays at 500 m. The coarser stratosphere and sponge improve the conditioning of
the anelastic pressure solve for the longest horizontal waves (∝ Δz², ~4× at the top) and save
~11% of the cells, like Breeze's TC-world RCE grid (1 km at a 28 km lid). Pass
`z_faces = MonsoonConvection.cm1_z_faces()` to `build_model` for CM1's original 65 levels.

## TKE closure

CM1's PBL scheme (`ipbl = 2`) limits the mixing length with `l_inf = 75 m` (namelist), which keeps
K ≲ 50 m² s⁻¹ for typical TKE. The `maximum_diffusivity` cap is the closest available substitute,
since Breeze's closure has no mixing-length limit. It caps K, not ℓ, so it is not the same as
CM1's formulation (README, "Changes to Breeze defaults").

## Sedimentation

CM1 substeps sedimentation. Breeze instead limits the time step by the fall speed
(`sedimentation_cfl`); substepping or implicit sedimentation upstream would remove that cost
(README, "Fall speeds in the time-step limit").

## EKAMSAT sounding experiments (CM1 case names)

Built in `helpers/ekamsat_soundings.jl` from the observed control; `cm1/soundings/README.md`
describes each.

```
control                                           (CM1 AS20230617)
└─ exp1  interp_1200_7200                         (AS12007200)
   └─ restore_4800m_level
      ├─ shear_set_4800m_u(u = −8, −7.2, −0.4)    (ASu4800-8, ASu4800-7p2, ASu4800-p4)
      └─ dry_layer(0.3 g/kg, 4800–7200 m)         (ASdry4800-7200)
         └─ shear_set_4800m_u(u = −8)             (ASdryu4800-8)
```

In the driver:

```julia
include(joinpath(repo, "helpers", "ekamsat_soundings.jl"))
control = ekamsat_control()
exp1    = interp_1200_7200(control)
dry     = dry_layer(restore_4800m_level(exp1), 0.3, (4800.0, 7200.0))
sounding = ekamsat_sounding(shear_set_4800m_u(dry; u = -8.0))    # = CM1 ASdryu4800-8
```

A CM1 `input_sounding` file (isnd = 7) can be read directly with `read_cm1_sounding(path)`.
