# P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU

## Summary

On a GPU, an `AtmosphereModel` with `P3Microphysics()` and a flux boundary condition on `ρE`
(and/or a `PolynomialCoefficient` bulk coefficient) fails at the first time step with a
`KernelError` in `fill_bottom_and_top_halo!`: the P3 lookup tables inside the boundary
condition are CPU `Array`s.

Cause: in `AtmosphereModel(...)` the boundary conditions are materialized with the
microphysics **before** it is moved to the device, and only `model.microphysics` is replaced:

- `src/AtmosphereModels/atmosphere_model.jl` (v0.11.3; same in main @ ed756e9):
  - ~L226: `materialize_atmosphere_model_boundary_conditions(boundary_conditions, grid, formulation, dynamics, microphysics, thermodynamic_constants)`
    embeds `microphysics` (CPU tables) in e.g. `EnergyFluxBoundaryConditionFunction`
    (`thermodynamic_variable_bcs.jl` L339–347) and `NearWallVirtualPotentialTemperature`
    (`polynomial_bulk_coefficient.jl`, used by `PolynomialCoefficient`).
  - ~L336: `microphysics = on_architecture(arch, microphysics)` moves the tables to the device
    afterwards. The copies already captured by the boundary conditions keep the host
    arrays, and `Adapt.adapt` on them at kernel launch cannot upload host `Array`s.

`materialize_dynamics(…, microphysics)` and `materialize_microphysical_fields(microphysics, …)`
also receive the CPU microphysics before the move; I haven't checked whether they keep it.

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
