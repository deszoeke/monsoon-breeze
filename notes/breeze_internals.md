# Breeze / Oceananigans internals we rely on

Checked against Breeze 0.11.3 and Oceananigans 0.113.5. Recheck after updating either.

- **Pressure solver precision.** `Breeze.AtmosphereModels.dynamics_pressure_solver(::AnelasticDynamics, grid)`
  builds a FourierTridiagonalPoissonSolver in the model's precision. We redefine it at runtime
  (`helpers/pressure_solver_precision.jl`); a package can't redefine it while precompiling.
- **P3 on GPU.** The boundary conditions capture the microphysics before `on_architecture`, so the
  CPU lookup tables end up in GPU kernels ("not isbits"). Workaround: build P3 with
  `on_architecture(arch, P3Microphysics())`.
- **TKE closure.** Mixing length ℓ = min(z, Cᴺ√e/N); where N² ≤ 0, ℓ = z (km-scale aloft).
  The default diffusivity caps are infinite.
- **Bounded WENO** (`WENO(order=5, bounds=(lo, hi))`). Zhang–Shu limiter (experimental),
  guaranteed only for total Courant number ≤ 5/18 with SSP stepping. Breeze applies it to the
  *specific* value (divides by ρ). Any field left out of a `scalar_advection` NamedTuple falls
  back to `Centered()`. The limiter can't pull values that are already out of bounds back in.
  Bounds tuples must be all the same float type.
- **Time step.** Breeze's `cell_advection_timescale(model)` uses (u, v, w) only. The
  `TimeStepWizard(cell_advection_timescale = f)` keyword overrides it (our
  `SedimentationLimitedTimescale`).
- **Sedimentation.** P3 fall speeds (`μ.wʳ, wⁿʳ, wⁱ, wⁿⁱ, wᶜˡ, wⁿᶜˡ`, at w faces, negative =
  down) are added to w in each hydrometeor's advection (`dynamics_kernel_functions.jl:150`).
  There is no sedimentation substepping.
- **AIVA** (adaptive implicit vertical advection, opt-in through
  `AdaptiveVerticallyImplicitDiscretization(cfl)`). The explicit flux is scaled by
  min(1, cfl/α), and an implicit upwind part uses wⁱ = w(1 − cfl/α). On the **anelastic** SSP-RK3
  path, the implicit part uses w *without* the fall speeds
  (`AtmosphereModels/implicit_vertical_advection.jl:70`), while the explicit part uses w + fall
  speed. So where the fall Courant number > cfl, sedimentation is stable but **too slow**. The
  compressible acoustic path includes the fall speeds (`acoustic_substep_helpers.jl:235`). It is
  probably a one-line upstream fix, which would make AIVA a cheap sedimentation fix.
