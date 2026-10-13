# Mixed-phase one-moment: uncapped rain–snow collection sinks drive rain and snow negative

## Summary

In `mpne1m_tendencies`, the rain–snow collection sinks are explicit and not limited by the mass
available. With the default CloudMicrophysics parameters their timescales are shorter than a
typical time step, so a single forward-Euler step (or SSP-RK3 stage) removes more than the cell
holds:

- below Tᶠ, snow collecting rain (`Sʳˢⁿ`) and ice–rain collisions (`Sᵃᶜᶜʳⁱ`) remove rain;
- above Tᶠ, rain collecting snow (`Sˢⁿʳ`) and warm-accretion melting (`α Sʳˢⁿ`, `α Sᵃᶜᶜˡˢⁿ`)
  remove snow.

The only limit is the gate q > ε. In a 3D convection run (Δx = 500 m, Δt ≈ 5 s), rain reaches
−2 g/kg and snow −0.3 g/kg at the melting level.

Breeze v0.11.3, CloudMicrophysics v0.40.1:
`ext/BreezeCloudMicrophysicsExt/one_moment_microphysics.jl:1259-1292`.

## MWE

```julia
using Breeze, CloudMicrophysics, SpecialFunctions
using Printf

Ext = Base.get_extension(Breeze, :BreezeCloudMicrophysicsExt)
P   = Ext.one_moment_cloud_microphysics_categories(Float64).parameters
pp  = P.process_params
rain, snow = P.precip.rain, P.precip.snow
vʳ, vˢⁿ    = P.terminal_velocity.rain, P.terminal_velocity.snow

ρ, Δt = 0.74, 5.0        # kg m⁻³ near 4.5 km; s
qʳ, qˢⁿ = 2e-3, 1.5e-3   # kg kg⁻¹

# Below Tᶠ, snow collecting rain removes rain (mpne1m_tendencies, ρqʳ: −Sʳˢⁿ)
Sʳˢⁿ = Ext.rain_snow_accretion(pp.rain_snow_accretion, snow, rain, vˢⁿ, vʳ, qˢⁿ, qʳ, ρ)
# Above Tᶠ, rain collecting snow removes snow (ρqˢⁿ: −Sˢⁿʳ)
Sˢⁿʳ = Ext.rain_snow_accretion(pp.rain_snow_accretion, rain, snow, vʳ, vˢⁿ, qʳ, qˢⁿ, ρ)

@printf "cold: rain τ = qʳ/Sʳˢⁿ  = %.2f s; one Euler step: qʳ  → %+.2f g/kg\n" qʳ/Sʳˢⁿ (qʳ - Δt*Sʳˢⁿ)*1e3
@printf "warm: snow τ = qˢⁿ/Sˢⁿʳ = %.2f s; one Euler step: qˢⁿ → %+.2f g/kg\n" qˢⁿ/Sˢⁿʳ (qˢⁿ - Δt*Sˢⁿʳ)*1e3
```

Output:

```
cold: rain τ = qʳ/Sʳˢⁿ  = 0.61 s; one Euler step: qʳ  → -14.41 g/kg
warm: snow τ = qˢⁿ/Sˢⁿʳ = 3.25 s; one Euler step: qˢⁿ → -0.81 g/kg
```

The rates themselves are correct: we re-derived the collection integral from the parameters and
got the same values. They are large mainly because of the snow N₀ (∝ (ρqˢⁿ)^0.63).

## Mitigation

In our runs, a `TendencyCallsite` callback recomputes these sinks with the same functions and
makes each one backward-Euler in the species it removes:

    S → S / (1 + Δt S / q).

It adds the difference back to the losing species and takes it from the gaining one, so water is
conserved and θˡⁱ is unchanged. Code:
[`helpers/implicit_rain_sink_correction.jl`](https://github.com/deszoeke/monsoon-breeze/blob/main/helpers/implicit_rain_sink_correction.jl).

Effect on the minima over ~600 iterations:
- rain: −2 → −0.02 g/kg;
- snow: −0.3 → −0.04 g/kg.

## Remaining problem

Small negatives remain, about 0.3% of each field's maximum, at and just below the melting level.
Each sink is now bounded on its own, but the total sink of a species is not. For example, snow
melting is capped at qˢⁿ/10 s, which removes about half the snow in a 5 s step, and it acts
together with the collection sinks.
