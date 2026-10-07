# Float32 anelastic pressure solve is unstable on wide, tall domains; please add a pressure-solver precision option

## Summary

In Float32, an `AtmosphereModel` with `AnelasticDynamics` on a 512 × 256 km, 28 km-deep domain
develops a temperature pattern in the top grid cell, the width of the whole domain, that grows
exponentially until the run fails with NaN (after ~15 simulated minutes). The same run in Float64
is stable.

We isolated the cause to the **anelastic pressure solve**: with the model in Float32 and only the
pressure solve in Float64, the run is stable and matches an all-Float64 run. With the model in
Float64 and only the pressure solve in Float32, it fails exactly like the all-Float32 run.

Breeze builds the pressure solver in the model's precision, with no way to choose otherwise. We
suggest an option to set the pressure solver's precision separately, so GPU runs can stay in
Float32 everywhere else.

## Setup

- Domain 512 × 256 km, periodic in x and y; rigid lid at 28 km. Vertical grid stretched from
  50 m at the surface to 500 m at 5 km, then 500 m to the top (65 levels).
- Tropical sounding (θ from 302 K at the surface to ~700 K at the top; density at the top ~1/50 of
  the surface value). Anelastic reference state built from the sounding.
- `AnelasticDynamics`, WENO(5), P3 microphysics, `TKEBasedTurbulenceClosure`, RRTMGP, bulk
  surface fluxes, f-plane. Rayleigh damping of w above 20 km.
- The failure reproduces on CPU at 4 km horizontal spacing (128 × 64 columns), so it can be
  debugged on a laptop in ~15 minutes. It also occurs on GPU (A100) at 500 m spacing.

## What happens in Float32

The spread (max − min) of temperature in the top cell grows by e-folds of ~100 s. Its pattern
is domain-scale (wavelength ≈ 512 km). Downstream, the turbulence closure and microphysics break
and the run ends in NaN.

- It does **not** occur on a 16 × 8 km domain with the same column, grid spacing and physics, on
  CPU or GPU.
- It is the same on CPU and GPU, and the same at 500 m and 4 km horizontal spacing.
- A much stronger sponge (relaxing u, v, θ, w with a 60 s time scale) only delays it, to ~1.7 h.

## Two-way precision experiment

Same configuration (CPU, 4 km spacing). Top-cell temperature range in K:

| Iteration | all Float64 | Float32 model + **Float64 solve** | all Float32 | Float64 model + **Float32 solve** |
|---|---|---|---|---|
| 100 | 216.01–216.19 | 216.02–216.19 | 215.90–216.31 | 215.90–216.30 |
| 150 | 216.01–216.19 | 216.02–216.20 | 215.13–217.10 | 215.13–217.10 |
| 200 | 216.03–216.20 | 216.04–216.20 | 201.66–231.35 | 201.66–231.34 |
| 400 | 216.10–216.30 | 216.10–216.30 | NaN at 211 | fails by ~210 |

The pressure solve's precision alone decides the outcome. Precision anywhere else in the model
doesn't matter.

## Why the pressure solve

The pressure equation is solved with FFTs in x and y, then a tridiagonal system in z for each
horizontal wavenumber k (`AnelasticTridiagonalSolverFormulation`). The diagonal of that system is
the sum of the neighboring vertical couplings (ρ/Δz terms) plus a term ρ Δz k². For the longest
wave (k = 2π/512 km) near the top, where ρ is small and Δz = 500 m, that extra term is tiny
compared with the couplings. Each elimination step then subtracts nearly equal numbers, and the
system's condition number is roughly (k Δz)⁻² ≈ 3×10⁴. Float32 keeps only ~7 significant digits.

For comparison, the TC-world RCE example (288 km, Δz = 1 km at a 28 km top) is about 13× better
conditioned for its longest wave, and runs fine in Float32.

## Suggested option

For example `AnelasticDynamics(reference_state; pressure_solver_float_type = Float64)`. In
`dynamics_pressure_solver`, build the solver on a copy of the grid in that precision, with the
reference density converted. We tested this as a runtime override in our project (Breeze 0.11.3):

```julia
function Breeze.AtmosphereModels.dynamics_pressure_solver(dynamics::AnelasticDynamics, grid)
    FT = Float64                                             # the requested solver precision
    solver_grid = RectilinearGrid(architecture(grid), FT;
                                  size = size(grid), halo = halo_size(grid), topology = topology(grid),
                                  x = (0, grid.Lx), y = (0, grid.Ly), z = Array(znodes(grid, Face())))
    ρᵣ = Field{Nothing, Nothing, Center}(solver_grid)
    set!(ρᵣ, Array(interior(dynamics.reference_state.density)))
    formulation = AnelasticTridiagonalSolverFormulation(ρᵣ)
    return FourierTridiagonalPoissonSolver(solver_grid; tridiagonal_formulation = formulation)
end
```

No other change was needed:

- The source term is computed on `solver.grid`, so the Float32 momentum divergence goes into the
  solver's Float64 storage.
- `solve!` converts the result back into the model's Float32 pressure field.

This sketch handles `RectilinearGrid` only. The immersed-boundary branch of
`dynamics_pressure_solver` would need the same treatment for the underlying grid.

A cheap warning could also help users: when building the solver, estimate (k_min Δz_top)⁻² and
warn in Float32 when it is large.

## Versions

Breeze 0.11.3, Oceananigans 0.113.5, CUDA.jl 6.4.2, Julia 1.13.1; CPU (Apple M3) and NVIDIA A100
80 GB.
