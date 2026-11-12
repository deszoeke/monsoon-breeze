# Changes to Breeze defaults

Moved from the README (2026-11-12), unchanged. The README keeps a one-line summary of each.

`MonsoonConvection` departs from Breeze's defaults or usual practice in the places below. Items 1,
2 and 4 are in `build_model`, item 5 in `build_simulation` (`MonsoonConvection/src/MonsoonConvection.jl`, "Model" section);
item 3 is the driver's default precision. Keep them in mind when interpreting results or comparing
with other Breeze runs.

## 1. TKE closure: eddy diffusivities capped at 100 m² s⁻¹ (safeguard; physics change only when active)

```julia
closure = TKEBasedTurbulenceClosure(; maximum_viscosity = maximum_diffusivity,
                                      maximum_tracer_diffusivity = maximum_diffusivity,
                                      maximum_tke_diffusivity = maximum_diffusivity)   # default 100 m² s⁻¹
```

- **Why.** Breeze's `TKEBasedTurbulenceClosure` (0.11.3) uses the mixing length
  ℓ = min(z, Cᴺ √e / N). Where the stratification is neutral or unstable (N² ≤ 0), ℓ falls back
  to z, the height above the ground. A locally unstable layer aloft therefore gets ℓ of order
  10–20 km, and K = Sᵘ ℓ √e of order 10⁴–10⁵ m² s⁻¹. Breeze's default caps are infinite.
- **What happened.** In the first full-domain GPU run, max Kᵘ jumped from ~40 to 3×10⁴ m² s⁻¹
  at iteration ~215, and the run failed with NaN at iteration 257. This turned out to be a
  **symptom** of the Float32 instability in item 3: the top cell became unstable and the closure
  responded with ℓ = z. In Float64 the cap never engages (max Kᵘ ≲ 50 m² s⁻¹, in the boundary
  layer). The cap stays as a safeguard against any unstable layer aloft.
- **Relation to CM1:** `notes/cm1_migration.md`, "TKE closure".
- **Effect.** It changes the physics only where K would exceed the cap. Normal maxima here are
  ~30–40 m² s⁻¹, in the boundary layer. Diagnose how often the cap is active by checking
  `maximum(model.closure_fields.Kᵘ)` (also printed with `debug_nan = true`).
- **Changing it.** Pass a different value from the driver, which needs no recompile:
  `build_model(sounding; arch, Nx, Ny, maximum_diffusivity = 50)`. `Inf` restores Breeze's
  default.
- **Upstream.** Worth raising with the Breeze developers: a mixing-length limit (e.g. a Blackadar
  form ℓ = κz / (1 + κz / ℓ∞)) or finite default caps would prevent the runaway at its source.

## 2. Microphysics built on the target architecture (bug workaround, no physics change)

`microphysics = on_architecture(arch, ...)`. Breeze 0.11.3 and 0.12.0 embed the microphysics in
the surface-flux boundary conditions before moving it to the GPU, so P3 GPU runs failed with "not
isbits" (CPU lookup tables inside a GPU kernel). Building the microphysics on the GPU first avoids
that; on CPU it does nothing. Breeze issue #1051, fixed on main by PR #1076 (2026-10-14) but not
yet in a release.

The default microphysics is now Breeze's mixed-phase one-moment scheme (non-equilibrium cloud
liquid and cloud ice, rain, snow; from CloudMicrophysics.jl) rather than P3, which is not
production ready in Breeze. `microphysics = :p3` restores P3. See `notes/one_moment_microphysics.md`.

## Vertical grid above 18 km (driver)

Above 18 km the driver's grid (`stretched_top_faces`) stretches Δz linearly from 500 m to about 1 km
at the 28 km lid (58 levels). This improves the conditioning of the pressure solve for the longest
horizontal waves. Set `Δz_top` in the driver. Why, and how to get CM1's 65 levels:
`notes/cm1_migration.md`, "Vertical grid".

## 3. Float64 pressure solve (numerical precision)

Breeze GPU examples run entirely in Float32. Here the **pressure solve always runs in Float64**
(`pressure_solver_type = Float64`, the default), because in Float32 it is unstable on the full
512 × 256 km domain. On GPU the rest of the model runs in Float32 (mixed precision, the default);
on CPU everything is Float64.

- **Symptom.** In Float32 the temperature in the top grid cell (27.5–28 km) develops a
  domain-scale pattern (wavelength ≈ the 512 km domain) that grows exponentially, by e-folds of
  ~100 s with the default w-only sponge. It becomes visible about 10–15 simulated minutes in.
  K then pins at the cap at 27.5 km, and the run ends in NaN in P3 ice number above 23 km
  (iteration ~240, ~16 min).
- **What it is not.** It is the same on CPU and GPU, and the same at 500 m and 4 km grid
  spacing on the full domain. It is absent on the 16 × 8 km test domain. A stronger sponge
  (`sponge_variables = :all`, `sponge_timescale = 60seconds`) only delays it, to ~1.7 h.
- **Float64 removes it.** Full domain on GPU at 500 m, 3 h: the top-cell spread stays below
  0.7 K, structure ~20 km, no cap, no NaN. The same holds on CPU at 4 km.
- **Cause: the Float32 anelastic pressure solve (confirmed).** A Float32 model with a Float64
  pressure solve is stable and matches all-Float64. A Float64 model with a Float32 pressure solve
  fails like all-Float32 (4 km test domain on CPU). The solve is poorly conditioned for the
  longest horizontal waves under a tall, strongly stratified column: roughly (k Δz)⁻² ≈ 3×10⁴ for
  a 512 km wave with Δz = 500 m, while Float32 keeps only ~7 digits. Breeze's TC-world RCE
  example (288 km, Δz = 1000 m at the top, about 13× better conditioned) runs in Float32. Draft
  issue: `breeze_issue_pressure_precision.md`.
- **Mixed precision (GPU default).** The model runs in Float32 with only the pressure solve in
  Float64 (`helpers/pressure_solver_precision.jl`). On the A100, full domain, it took 0.67 s per
  step against 1.3 s for all-Float64, about 2× faster. A 4-day run (~43,000 steps at Δt ≈ 8 s)
  takes about 8 h instead of 15 h. Through 1 h its diagnostics matched all-Float64 to the printed
  precision. It works by redefining Breeze's solver construction for the session (written
  against Breeze 0.11.3, checked on 0.12.0; it warns on other versions), so it's a stopgap until Breeze has such an
  option. All-Float64 remains available with `float_type = Float64`.

The `sponge_variables = :all` option (relax u, v, θ in the sponge layer) remains available,
but is not needed in Float64.

## 4. Bounded (positivity-preserving) WENO scalar advection

Every advected scalar uses `WENO(order=5, bounds=(min, max))` (`build_model`, keyword
`bounded_scalar_advection = true`; bounds in `MonsoonConvection.scalar_bounds`). Breeze's default
is unbounded WENO(5).

- **Why.** Unbounded WENO can undershoot below zero at sharp edges, such as updraft and cloud
  edges. Negative moisture, hydrometeor or number values can then make P3 produce NaN. The
  first full-domain mixed-precision run failed with NaN at 17.5 h, at the onset of deep
  convection. Breeze's TC-world RCE example, which runs strong convection in Float32, bounds its
  moisture the same way. In a forced-condensation test, unbounded advection gave cloud and rain
  minima of about −10⁻¹⁴; bounded advection keeps them at exactly 0. The physics is otherwise the
  same.
- **How.** Oceananigans' Zhang–Shu (2010) limiter (marked experimental) scales each cell's
  reconstructions toward the cell mean, so that advection keeps the **specific** value
  (kg/kg, K, per kg; Breeze divides by ρ) inside the bounds. Every field is named, because any
  field left out of the NamedTuple would fall back to second-order `Centered` advection.

  | Fields | Quantity | Bounds |
  |---|---|---|
  | `ρqᵛ`, `ρqᶜˡ`, `ρqʳ`, `ρqⁱ`, `ρqᶠ`, `ρqʷⁱ` | mass fractions | (0, 1) |
  | `ρnʳ`, `ρnⁱ` | number per kg | (0, 10²⁰) |
  | `ρbᶠ` | rime volume per kg (m³ kg⁻¹) | (0, 1) |
  | `ρe` | TKE (m² s⁻²) | (0, 10⁶) |
  | `ρθ` | liquid-ice potential temperature (K) | (150, 2000) |

  Upper bounds are physical maxima, chosen loose so they never clip real values. The limiter acts
  only where a reconstruction would leave the bounds.
- **Not a strict guarantee here.** The limiter is guaranteed only for total Courant number
  ≤ 5/18. We run at CFL 0.7, as Breeze's TC world does, which removes most undershoots but not
  provably all.
- **Sources must stay inside the bounds.** The limiter assumes the cell values are already
  inside the bounds, and sources (radiation, latent heating, microphysics) can push them out. The driver checks the
  specific range of every bounded field every 10 iterations. It warns (once per field; every
  time with `debug_nan = true`) if a field leaves its bounds, which means the limiter is unreliable
  there.
- **Comparing.** `bounded_advection = false` restores Breeze's unbounded WENO(5) for all scalars.

## 5. Fall speeds in the time-step limit (`sedimentation_cfl`, on by default)

P3 moves each hydrometeor field by adding its fall speed to w in that field's advection. Breeze's
time-step wizard limits Δt with u, v and w only, so the fall speed never constrains Δt, and
Breeze 0.11.3 has no sedimentation substepping. Its adaptive implicit vertical advection leaves out
the fall speeds on the anelastic path. Rain falls at up to ~9 m/s, and dense rimed ice at
10–20 m/s. In the 50 m lowest cell at Δt ≈ 8 s, the fall Courant number |w + w_fall| Δt / Δz
exceeds 1, and explicit WENO is unstable there.

- **Evidence.** In a forced-condensation test (small domain, CPU), rain alone reached a fall
  Courant number of 1.3–2.1 at Δt ≈ 8 s. The full-domain runs (mixed precision, bounded or
  unbounded advection) all failed at the onset of deep convection (~17.5 h, iteration
  ~7930–8000). Ice number went NaN first, from the lowest cell up, after max ice mass grew to
  5 g/kg.
- **Fix.** `sedimentation_cfl = true` (`build_simulation(...; sedimentation_cfl = true)`) also limits
  Δt so that the fall Courant number ≤ `cfl` (0.7). In the test, Δt fell from ~8 s to ~3.5–4 s
  while rain was present, so heavy precipitation costs roughly 2× more.
  `debug_nan = true` prints the maximum fall Courant number and its height every 10 iterations.
- **Better long-term fix (upstream).** Sedimentation substepping, or implicit
  sedimentation, would remove the cost.
