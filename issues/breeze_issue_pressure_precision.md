# Add a pressure-solver precision option to avoid unstable Float32 anelastic pressure solve on large domains

## Summary

GPUs are 2x faster at Float32, but an ill-conditioned anelastic pressure solver for physically tall and wide domains crash with Float32 precision. Breeze can still get nearly 2x speedup for a 512x256x28 km simulation with Float32, stabilized by overriding `AtmosphereModels.dynamics_pressure_solver` to use Float64:
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
This forces a Float64 copy just for the pressure solver.

## Suggestion
We suggest an option to set the pressure solver's precision separately, so the model can use Float32 everywhere else, but Float64 for the pressure solver.

## Crashing pressure solver with Float32
In Float32, an `AtmosphereModel` with `AnelasticDynamics` on a 512 × 256 km, 28 km-deep domain
develops a temperature pattern in the top grid cell, the width of the whole domain, that grows
exponentially until the run fails with NaN after ~15 simulated minutes. Running entirely with Float64 is stable. Using Float64 just for the pressure solve and Float32 otherwise is also stable and almost as efficient as entirely Float32.

We isolated the **anelastic pressure solver** as the cause: with the model in Float32 and only the
pressure solve in Float64, the run is stable and matches an all-Float64 run. With the model in
Float64 and only the pressure solve in Float32, it fails exactly like the all-Float32 run.

Breeze builds the pressure solver in the model's precision, with no way to choose otherwise.

### MWE setup

- Domain 512 × 256 km, periodic in x and y; rigid lid at 28 km. Vertical grid stretched from
  50 m at the surface to 500 m at 5 km, then 500 m to the top (65 levels).
- Tropical sounding (θ from 302 K at the surface to ~700 K at the top; density at the top ~1/50 of
  the surface value). Anelastic reference state built from the sounding.
- `AnelasticDynamics`, WENO(5), P3 microphysics, `TKEBasedTurbulenceClosure`, RRTMGP, bulk
  surface fluxes, f-plane. Rayleigh damping of w above 20 km.
- The failure reproduces on CPU at 4 km horizontal spacing (128 × 64 columns), and GPU (A100) at 500 m spacing.

The spread (max − min) of temperature in the top cell grows by e-folds of ~100 s. Its pattern
is domain-scale (wavelength 512 km). The turbulence closure and microphysics result in NaN.

- It does **not** occur on a 16 × 8 km domain with the same column, grid spacing and physics, on
  CPU or GPU.
- It is the same on CPU and GPU, and the same at 500 m and 4 km horizontal spacing.
- A much stronger sponge (relaxing u, v, θ, w with a 60 s time scale) only delays it, to ~1.7 h.

### Versions

Breeze 0.11.3, Oceananigans 0.113.5, CUDA.jl 6.4.2, Julia 1.13.1; CPU (Apple M3) and NVIDIA A100
80 GB.
