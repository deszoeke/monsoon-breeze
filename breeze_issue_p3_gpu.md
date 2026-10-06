# P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU

## Summary

On a GPU, an `AtmosphereModel` with `P3Microphysics()` and a flux boundary condition on `ρE`
(and/or a `PolynomialCoefficient` bulk coefficient) fails at the first time step with a
`KernelError` in `fill_bottom_and_top_halo!`: the P3 lookup tables inside the boundary
condition are CPU `Array`s.

## Cause

The P3 microphysics includes lookup tables, which must be in GPU memory for a GPU run.

The surface-flux boundary conditions **contain their own copy of the P3 microphysics**,
because they use it to compute moisture at the surface. That copy is made when the
boundary conditions are built.

In the `AtmosphereModel` constructor, the boundary conditions are built **before** P3's tables
are moved to the GPU. So:

- the boundary conditions get P3 with its tables in **CPU** memory, and keep it;
- the model's own microphysics (`model.microphysics`) is then moved to the GPU;
- the boundary conditions' copy is never updated.

At the first time step, the GPU runs the boundary-condition code, finds the CPU tables in it,
and fails ("not isbits": GPU code can only use data in GPU memory).

**The fix is to move P3's tables to the GPU before the boundary conditions are built,** so the
boundary conditions copy the GPU version.

Where this happens (Breeze v0.11.3; the same in main @ ed756e9), in
`src/AtmosphereModels/atmosphere_model.jl`:

- ~line 226: `materialize_atmosphere_model_boundary_conditions(..., microphysics, ...)` builds the
  boundary conditions, copying P3 into `EnergyFluxBoundaryConditionFunction`
  (`thermodynamic_variable_bcs.jl` lines 339–347, used for any flux boundary condition on `ρE`)
  and into `NearWallVirtualPotentialTemperature` (`polynomial_bulk_coefficient.jl`, used by
  `PolynomialCoefficient`).
- ~line 336: `microphysics = on_architecture(arch, microphysics)` moves the tables to the GPU,
  too late for the boundary conditions.

`materialize_dynamics` and `materialize_microphysical_fields` are also called with P3 before
line 336. I haven't checked whether they keep a copy too.

## Minimal example

```julia
using Breeze, Oceananigans, CUDA

grid = RectilinearGrid(GPU(); size = (8, 8, 8), extent = (1000, 1000, 1000))
reference_state = ReferenceState(grid; base_pressure = 101325, potential_temperature = 300)
ρE_bcs = FieldBoundaryConditions(bottom = FluxBoundaryCondition(100))

model = AtmosphereModel(grid; dynamics = AnelasticDynamics(reference_state),
                        microphysics = P3Microphysics(),
                        boundary_conditions = (; ρE = ρE_bcs))
set!(model; θ = 300, qᵗ = 0.01)
time_step!(model, 1)   # KernelError: ... not isbits
```

On CPU this runs, and
`model.formulation.potential_temperature_density.boundary_conditions.bottom.condition.microphysics === model.microphysics`
is `true`, because `on_architecture(CPU(), p3)` returns the same object. On GPU the two
diverge.

The example above was not run on a GPU as written. It is reduced from a full model that
fails this way: `P3Microphysics()`, `BulkSensibleHeatFlux`/`BulkVaporFlux`/`BulkDrag` with
`PolynomialCoefficient()` on `ρE`/`ρqᵗ`/`ρu`/`ρv`, `AnelasticDynamics`, RRTMGP,
`TKEBasedTurbulenceClosure`, Float32.

## Error (excerpt)

```
.mass_weighted is of type Breeze.Microphysics.PredictedParticleProperties.RimeDensityIndexedTable4D{Oceananigans.Utils.TabulatedFunction{4, Nothing, Array{Float32, 4}, ...}} which is not isbits.
  .table is of type Oceananigans.Utils.TabulatedFunction{4, Nothing, Array{Float32, 4}, ...} which is not isbits.
    .table is of type Array{Float32, 4} which is not isbits.
...
.rain is of type ...RainDrops{Float32, Oceananigans.Utils.TabulatedFunction{1, Nothing, Vector{Float32}, ...}, ...} which is not isbits.
...
Stacktrace:
  [1] check_invocation(job::GPUCompiler.CompilerJob)
 ...
 [19] cufunction(f::typeof(Oceananigans.BoundaryConditions.gpu__fill_bottom_and_top_halo!), ...
      BoundaryCondition{Oceananigans.BoundaryConditions.Flux{...
```

## Workaround

Move P3 to the device before constructing the model, so the boundary conditions and the
model share the device copy:

```julia
microphysics = Oceananigans.Architectures.on_architecture(GPU(), P3Microphysics())
```

## Suggested fix

Move `microphysics = on_architecture(arch, microphysics)` to the top of `AtmosphereModel`,
before `materialize_atmosphere_model_boundary_conditions`, so every component that captures
the microphysics gets the device copy. A GPU test combining P3 with any `ρE` flux boundary
condition would catch regressions.

## Versions

Breeze 0.11.3 (same code in main @ ed756e9), Oceananigans 0.113.5, CUDA.jl 6.4.2 (CUDACore),
Julia 1.13.1, NVIDIA A100 80GB PCIe, driver 595.45.04 (CUDA 13.2).
