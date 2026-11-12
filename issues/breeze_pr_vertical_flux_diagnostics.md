# Breeze.jl PR guide: vertical flux diagnostics

Upstream issue: Breeze #1250.

Written 2026-11-12, from the work in `MonsoonConvection/src/MonsoonConvection.jl` (functions
`resolved_fluxes`, `subgrid_fluxes`, `sedimentation_fluxes`, `surface_fluxes`, `water_species`,
`flux_profiles`). Checked against Breeze 0.13.1 and Oceananigans 0.116.1. The code ran in a 1 h CPU small
test (P3 microphysics) and matched expectations for momentum, θ and vapor; the hydrometeor and
sedimentation fluxes are written but were zero (no condensate yet), so they are **untested**. GPU untested.

## Why

Breeze has no standard vertical-flux diagnostics. Some examples compute fluxes in the driver, but each user
has to write them, and the way they do it is imprecise:

- `examples/tropical_cyclone_world.jl:244-249` averages the raw product, `Average(w * θ, dims=(1, 2))`. That
  is ⟨w′θ′⟩ + ⟨w⟩⟨θ⟩, and ⟨w⟩⟨θ⟩ ≈ 300 K × ⟨w⟩: a mean vertical velocity of 1e-3 m/s (large-scale motion or
  numerical noise) adds 0.3 K m/s, more than a typical boundary-layer heat flux. It is the turbulent flux only
  if ⟨w⟩ is exactly zero.
- `examples/neutral_atmospheric_boundary_layer.jl:205-221` averages raw moments (`uw`, `θw`, `uu`, ...) and
  subtracts the means afterwards (`uu_n - u_n^2`, lines 332-334). Two nearly equal large terms leave a small
  difference, dominated by rounding error, which is much worse in Float32.

The covariance should be formed on the anomalies, ⟨a′w′⟩ with a′ = a - ⟨a⟩, so nothing large cancels. This
matters most in Float32, the goal on GPU. Nothing in Breeze exposes the subgrid, sedimentation or surface
fluxes either, though an LES budget needs all of them. In Breeze none of them is stored: the closure flux is
applied inside the tendency kernels (inside the tridiagonal solve for the default implicit TKE closure),
sedimentation is advection with the fall speed, and the bulk surface fluxes are evaluated inline in the
boundary-condition kernel.

Open question for the PR: whether this belongs in `AtmosphereModel`. Breeze does not create output fields for
profiles or surfaces; users assemble them from diagnostics (`KernelFunctionOperation`s returned by
`AtmosphereModels/Diagnostics/`). In MonsoonConvection the output set is built in `build_simulation`, which is
why the fluxes live there. In Breeze they would most naturally be diagnostics (functions of the model that
return operations), not model state; whether a standard output set (a named tuple for profile and surface
writers) belongs in `AtmosphereModel` is for the maintainers (issue #1250).

## What we have (all kinematic, upward-positive, on z faces, zero at the top face; bottom face see below)

| Quantity | Name here | How |
|---|---|---|
| Resolved ⟨w′a′⟩ | `wu`, `wv`, `wtheta`, `wq<species>` | `Average(@at((Center, Center, Face), (a - Field(Average(a))) * (w - Field(Average(w)))), dims=(1, 2))` |
| Subgrid (closure) | `F_u_sgs`, `F_v_sgs`, `F_theta_sgs`, `F_<q>_sgs` | the closure's own `viscous_flux_{u,v}z` and `diffusive_flux_z`, called with `ExplicitTimeDiscretization()` |
| Sedimentation ⟨q w_fall⟩ | `F_<q>_sed` | from `model.sedimentation` (`.velocity`, `.specific_humidity`): `q[k] * w_fall[k]` at face k |
| Surface (bulk BC) | `F_u_sfc`, `F_v_sfc`, `F_theta_sfc`, `F_qv_sfc` | `BoundaryConditionOperation(ρa, :bottom, model)` divided by the lowest-level density |

Total flux of a species at an interior face = resolved + subgrid + sedimentation; at z = 0 the surface flux
(vapor, θ, momentum) and the sedimentation flux (precipitation). Averaging uses `Average(..., dims=(1, 2))`
inside the output writer, so it is fused and needs no stored temporaries; the whole set is switched by one
option (`flux_outputs`) that builds none of the operations when false.

## Design points worth keeping in a PR

- **Two passes, not ⟨aw⟩ - ⟨a⟩⟨w⟩.** Deviations from the instantaneous horizontal-mean Field. Tested on plain
  Oceananigans CPU fields: θ flux matches an offline float64 reference to 4e-10 in Float32; the mean Fields
  refresh whenever the outer operation is evaluated (no stale means). Fill halos before testing (an unfilled
  periodic halo gave a 5% error in a test).
- **Face location.** w lives on z faces and the flux divergence is taken to centers; `@at((Center, Center, Face), ...)`
  interpolates a to faces. The resolved flux is then exactly zero at the bottom and top faces (w = 0).
- **Closure fluxes through the closure interface, not -K ∂z c.** `TKEBasedTurbulenceClosure` is vertically
  implicit, so with its own discretization the explicit flux functions return zero at interior faces
  (`abstract_scalar_diffusivity_closure.jl`, the `VITD` methods keep only k = 1 and Nz+1). Passing
  `ExplicitTimeDiscretization()` as the discretization argument strips it and calls the closure-dispatched
  method, so any `AbstractScalarDiffusivity` (Smagorinsky, AMD, CATKE, ...) works unchanged. Guard: a closure
  that is not an `AbstractScalarDiffusivity` (nonlocal, mass-flux) hits the zero fallbacks of
  `AbstractTurbulenceClosure`, so the diagnostic must raise an error until that closure's flux is defined.
  A proper PR could add a trait or a `vertical_flux` generic function that closures extend. Do not
  multiply by ρ: Breeze's `Jᶜz = ℑzᵃᵃᶠ(ρ) * _diffusive_flux_z` weights the same kinematic flux.
- **Scalar ids.** The closure indexes scalars by position: `Val(1)` thermodynamic, `Val(2)` moisture,
  `Val(i + 2)` for the i-th microphysical prognostic (`closure_scalar_names`,
  `update_atmosphere_model_state.jl:403-419`), with the *specific* field as `c`
  (`microphysical_fields[specific_field_name(name)]`).
- **Bottom/top faces.** The explicit formula at k = 1 and Nz+1 reads halo values; mask both to zero in the
  profile. The bottom-face flux is the boundary condition, available as `BoundaryConditionOperation`
  (Breeze already re-exports it). `bottom_precipitation_flux(model)` exists but is one 2D total over all
  sedimenting condensates (kg m-2 s-1), not per species and not a profile.
- **Sedimentation flux.** Breeze never forms it: `model.sedimentation` holds the fall speeds
  (ZFace, negative downward, stored at the bottom face of the cell the speed belongs to) and the advection
  scheme applies them. We use the first-order upwind estimate `q[k] w_fall[k]`; the actual WENO reconstruction
  differs slightly. A PR could expose the flux from the scheme's own reconstruction, at the cost of
  touching the advection code.
- **Moisture id.** Vapor uses id 2 and `specific_humidity(model)`; for SaturationAdjustment the id-2 scalar is
  qᵉ (equilibrium moisture), so a general version should use `specific_prognostic_moisture(model)` and label it.
- **Dynamics.** Surface fluxes divide by `dynamics_density(model.dynamics)[i, j, 1]`; the anelastic reference
  density is a reduced field. A compressible model has a full density field. `kinematic_surface_flux` indexes
  `[i, j, 1]` for both.

## Where it could live in Breeze

`src/AtmosphereModels/Diagnostics/` already returns `KernelFunctionOperation`s (e.g. `static_energy.jl:91`,
`potential_temperatures.jl`), with the TitleCase-returns-KFO convention in
`docs/src/atmosphere_model/diagnostics.md`. Suggested: a `vertical_fluxes.jl` there with
`ResolvedVerticalFlux(model, a)`, `SubgridVerticalFlux(model, name)`, `SedimentationFlux(model, name)`,
`SurfaceFlux(model, name)`, plus a convenience that returns the named set for a model, tests in `test/`
(a column with a known K and gradient; a uniform-w check that the resolved flux is zero; the two-pass
precision check; a closure-swap check; sedimentation against `bottom_precipitation_flux`), and a docs page.

## A standard set of calls

Diagnostics live outside the model: `AtmosphereModel` stores prognostic fields, velocities, closure fields,
`microphysical_fields` and `sedimentation`, and diagnostics are functions of the model that return
`KernelFunctionOperation`s (`AtmosphereModels/Diagnostics/`). The flux diagnostics need no new model state;
they read `model.velocities`, `model.closure` and `model.closure_fields`, `model.sedimentation`,
`model.momentum`, `model.moisture_density`, `thermodynamic_density(model.formulation)` and the bottom boundary
conditions. They do rely on internals users should not have to track (the closure's scalar-index order,
`specific_field_name`, `model.sedimentation`, which closures are diffusivity closures), so a standard set
belongs in Breeze next to those internals, where it changes with them. Proposal, each returning a named tuple
of operations or `Average`s that an output writer takes directly:

```julia
profile_outputs(model; fluxes = true)   # horizontal means: u v w θ T qᵛ, microphysics mass fractions and numbers
vertical_flux_outputs(model)            # resolved wu wv wtheta wq*, subgrid F_*_sgs, sedimentation F_*_sed (z faces)
surface_flux_outputs(model)             # F_u_sfc F_v_sfc F_theta_sfc F_qv_sfc, and F_*_sed at the bottom face
output_attributes(outputs)              # long_name and units for every name, so files are self-describing
```

- Time averaging, intervals and the writer stay with the user (`AveragedTimeInterval`, `TimeInterval`).
- The names and the long_name/units table are the shared convention, so profile files look alike across
  experiments. In MonsoonConvection that table is `netcdf_attributes` and `flux_attributes`.
- `fluxes = false` skips every flux operation (none built, evaluated or stored), as `flux_outputs` does here.
- The microphysics species list comes from the scheme (`prognostic_field_names`, `model.sedimentation`), so
  it follows one-moment or P3 automatically.
- Whether this standard set is a function of the model or part of `AtmosphereModel` is for the maintainers
  (issue #1250); the diagnostics pattern keeps it outside the model.

## Output architecture in MonsoonConvection (for discussion)

`build_simulation(model; ...)` combines the model and the outputs: it builds the profile (horizontal-mean),
surface (lowest-level) and 3D-field writers and a checkpointer from a hard-coded output set, configurable only
by intervals. The flux diagnostics are members of the profiles and surface files, built from model fields
outside the model. `flux_outputs` (a boolean) is a minimal hack that configures this output code (it switches
those members off, building none of the operations); it is not a designed interface and is kept as a simple
switch pending the developers' view. A cleaner design would be one outputs object or function holding the
output selections, files and frequencies, passed to `build_simulation` (model and outputs stay separate, and
combine there); the standard-set functions above would be its building blocks.

## Before proposing

1. Run on GPU: the KFOs capture `Oceananigans.fields(model)` and the closure. Breeze notes (`BoundaryConditions.jl`,
   `dynamics_thermodynamic_fields`) say heterogeneous merged field tuples have broken GPU kernel compilation,
   so mirror `surface_layer_state` or pass the pieces separately. `size(grid, 3)` and `zero(grid)` inside
   kernels also need a GPU check.
2. Test with condensate (long run): hydrometeor resolved/subgrid/sedimentation fluxes, `F_<q>_sed` at z = 0 against
   `bottom_precipitation_flux * 1/ρ`, and the budget: total flux divergence against the species tendency.
3. Check the open θ result: in the 1 h test `F_theta_sgs` was +1.3e-4 at 50 m and -2.8e-3 at 124 m while the surface
   flux was +2.7e-3 (see `notes/STATUS.md`, "Flux outputs"); it may be a stable layer above a freshly heated
   lowest cell, or a bug.
4. Decide whether ρ-weighted or kinematic is the default (we write kinematic, upward-positive, comparable
   with CM1 and the usual ⟨w′a′⟩), and whether to expose the surface flux per species including rain.
5. Contact the Breeze developers first: issue #1250 is open with Breeze (2026-11-12) for this; link the PR to it and
   follow the discussion there before writing the PR.
