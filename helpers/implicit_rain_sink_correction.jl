# Make the rain–snow collection sinks of Breeze's mixed-phase one-moment microphysics implicit.
# Included by monsoon_convection.jl when implicit_rain_sink = true; not run directly.
#
# Retired: Breeze PR #1066 closed the issue (#1072); from Breeze 0.12.1 it limits these rates
# itself. This correction is sized from the unlimited rates, so on top of #1066 it drives snow far
# negative (the idealized control's NaN at 12 h, notes/nan_investigation.md). There it warns and
# does nothing. Still applied with Breeze 0.12.0.
#
# Why: rain and snow collect each other, and the losing species' sink is explicit and not limited
# by what the cell holds. With the default parameters the collection timescales are ~0.6–4 s at
# g/kg amounts, shorter than Δt ≈ 4–5 s, so one step can take more than the cell holds:
#   - cold (T < Tᶠ = 273.15 K): rain → snow by snow collecting rain (Sʳˢⁿ) and ice–rain
#     collisions (Sᵃᶜᶜʳⁱ, all T); rain went negative at the melting level
#     (helpers/rain_snow_accretion_check.jl; Gaudet & Schmidt 2007 on collection overdepletion);
#   - warm (T ≥ Tᶠ): snow → rain by rain collecting snow (Sˢⁿʳ) and snow melted by accreted warm
#     rain and cloud liquid (α Sʳˢⁿ, α Sᵃᶜᶜˡˢⁿ); snow went negative just below the melting level
#     once rain was fixed (log of 2026-10-13, iterations 63500–64170).
# The routing is mpne1m_tendencies' (ext/BreezeCloudMicrophysicsExt/one_moment_microphysics.jl:1287-1292).
#
# How: each sink is about linear in its species, S = q/τ. A TendencyCallsite callback replaces
# Breeze's explicit S by the backward-Euler S/(1 + Δt S/q) = q/(τ + Δt), i.e. adds back
#     δ = ρ S x / (1 + x),   x = Δt S / q = Δt/τ,
# to the losing species and takes it from the gaining one, so water is conserved. Rain and snow
# exchange only with each other here, so one net field moves Δ = δʳ − δˢⁿ from snow to rain.
# θˡⁱ needs no change: it is conserved through phase changes, and Breeze has no microphysical ρθ
# tendency. The rates are Breeze's own, recomputed from the same parameters, ρ and T. Δt is the
# full step, which is the stage step of SSP-RK3 and errs on the strong side for other RK schemes.

using Breeze, Oceananigans
using Oceananigans: TendencyCallsite

const RainSinkExt = Base.get_extension(Breeze, :BreezeCloudMicrophysicsExt)

# Backward-Euler correction ρ S x/(1+x) for a sink S of species q; S is gated to 0 for q ≤ ε
@inline function implicit_excess(ρ, S, q, Δt)
    x = Δt * S / max(q, floatmin(q))
    return ρ * S * x / (1 + x)
end

@inline function implicit_rain_sink_correction(i, j, k, grid, ρ, T, ρqʳ, ρqˢⁿ, ρqᶜⁱ, ρqᶜˡ,
                                               parameters, Tᶠ, constants, Δt)
    @inbounds begin
        ρᵢ = ρ[i, j, k]
        qʳ = ρqʳ[i, j, k] / ρᵢ
        qˢⁿ = ρqˢⁿ[i, j, k] / ρᵢ
        qᶜⁱ = ρqᶜⁱ[i, j, k] / ρᵢ
        qᶜˡ = ρqᶜˡ[i, j, k] / ρᵢ
        Tᵢ = T[i, j, k]
    end
    rain, snow = parameters.precip.rain, parameters.precip.snow
    rain_velocity, snow_velocity = parameters.terminal_velocity.rain, parameters.terminal_velocity.snow
    process = parameters.process_params

    # The same calls as mpne1m_tendencies
    Sʳˢⁿ = RainSinkExt.rain_snow_accretion(process.rain_snow_accretion, snow, rain,
                                           snow_velocity, rain_velocity, qˢⁿ, qʳ, ρᵢ)
    Sˢⁿʳ = RainSinkExt.rain_snow_accretion(process.rain_snow_accretion, rain, snow,
                                           rain_velocity, snow_velocity, qʳ, qˢⁿ, ρᵢ)
    Sᵃᶜᶜʳⁱ = RainSinkExt.rain_sink_accretion(process.cloud_ice_rain_accretion, rain, parameters.cloud.ice,
                                             rain_velocity, qᶜⁱ, qʳ, ρᵢ)
    Sᵃᶜᶜˡˢⁿ = RainSinkExt.cloud_precipitation_accretion(process.cloud_liquid_snow_accretion,
                                                       parameters.cloud.liquid, snow, snow_velocity, qᶜˡ, qˢⁿ, ρᵢ)
    α = RainSinkExt.warm_accretion_melt_factor(Tᵢ, Tᶠ, constants)
    is_warm = Tᵢ ≥ Tᶠ

    Sʳ = Sᵃᶜᶜʳⁱ + ifelse(is_warm, zero(Sʳˢⁿ), Sʳˢⁿ)                       # rain → snow
    Sˢⁿ = ifelse(is_warm, Sˢⁿʳ + α * (Sʳˢⁿ + Sᵃᶜᶜˡˢⁿ), zero(Sˢⁿʳ))      # snow → rain

    # Net mass to move from snow back to rain
    return implicit_excess(ρᵢ, Sʳ, qʳ, Δt) - implicit_excess(ρᵢ, Sˢⁿ, qˢⁿ, Δt)
end

function add_implicit_rain_sink_correction!(simulation)
    if pkgversion(Breeze) ≥ v"0.12.1"
        @warn "implicit_rain_sink is no longer needed and is ignored: Breeze PR #1066 closed the issue " *
              "(#1072) in Breeze 0.12.1 (this is $(pkgversion(Breeze))), and this correction would drive " *
              "snow negative on top of it. Set implicit_rain_sink = false."
        return nothing
    end
    model = simulation.model
    haskey(model.microphysical_fields, :ρqˢⁿ) ||
        error("implicit_rain_sink = true supports mixed-phase one-moment microphysics only")
    μ = model.microphysical_fields
    categories = model.microphysics.categories
    ρ = Breeze.AtmosphereModels.total_density(model.dynamics)
    FT = eltype(model.grid)
    Δ = CenterField(model.grid)   # storage reused every stage; Δt changes, so the operation is rebuilt

    function correct_rain_sink!(model)
        correction = KernelFunctionOperation{Center, Center, Center}(
            implicit_rain_sink_correction, model.grid, ρ, model.temperature,
            μ.ρqʳ, μ.ρqˢⁿ, μ.ρqᶜⁱ, μ.ρqᶜˡ, categories.parameters, categories.freezing_temperature,
            model.thermodynamic_constants, FT(simulation.Δt))
        compute!(Field(correction; data = Δ.data))
        interior(model.timestepper.Gⁿ.ρqʳ) .+= interior(Δ)
        interior(model.timestepper.Gⁿ.ρqˢⁿ) .-= interior(Δ)
        return nothing
    end

    add_callback!(simulation, correct_rain_sink!; callsite = TendencyCallsite())
    return nothing
end
