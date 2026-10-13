# Make the rain sinks of Breeze's mixed-phase one-moment microphysics implicit. Included by
# monsoon_convection.jl with --implicit_rain_sink; not run directly.
#
# Why: below Tᶠ = 273.15 K, snow collecting rain (Sʳˢⁿ) and ice–rain collisions (Sᵃᶜᶜʳⁱ) remove
# rain explicitly and are not limited by the rain available. With the default parameters the
# snow-collects-rain timescale is τ ≈ 0.6–4 s at 1.6 g/kg snow, shorter than Δt ≈ 4 s, so one step
# takes more rain than the cell holds and leaves qʳ < 0 at the melting level
# (helpers/rain_snow_accretion_check.jl; Gaudet & Schmidt 2007 on collection overdepletion).
#
# How: the sink is about linear in qʳ, S = qʳ/τ. A TendencyCallsite callback replaces Breeze's
# explicit S by the backward-Euler S/(1 + Δt S/qʳ) = qʳ/(τ + Δt). It adds the difference
#     δ = ρ S x / (1 + x),   x = Δt S / qʳ = Δt/τ,
# to Gρqʳ and subtracts it from Gρqˢⁿ (both sinks feed snow), so water is conserved. θˡⁱ needs
# no change: it is conserved through phase changes, and Breeze has no microphysical ρθ tendency.
# The rates are Breeze's own, recomputed from the same parameters, ρ and T. Δt is the full step,
# which is the stage step of SSP-RK3 and errs on the strong side for other RK schemes.

using Breeze, Oceananigans
using Oceananigans: TendencyCallsite

const RainSinkExt = Base.get_extension(Breeze, :BreezeCloudMicrophysicsExt)

@inline function implicit_rain_sink_correction(i, j, k, grid, ρ, T, ρqʳ, ρqˢⁿ, ρqᶜⁱ, parameters, Tᶠ, Δt)
    @inbounds begin
        ρᵢ = ρ[i, j, k]
        qʳ = ρqʳ[i, j, k] / ρᵢ
        qˢⁿ = ρqˢⁿ[i, j, k] / ρᵢ
        qᶜⁱ = ρqᶜⁱ[i, j, k] / ρᵢ
        Tᵢ = T[i, j, k]
    end
    rain, snow = parameters.precip.rain, parameters.precip.snow
    rain_velocity, snow_velocity = parameters.terminal_velocity.rain, parameters.terminal_velocity.snow
    process = parameters.process_params

    # The same calls as mpne1m_tendencies: rain collected by snow (cold branch only) and by cloud ice
    Sʳˢⁿ = RainSinkExt.rain_snow_accretion(process.rain_snow_accretion, snow, rain,
                                           snow_velocity, rain_velocity, qˢⁿ, qʳ, ρᵢ)
    Sᵃᶜᶜʳⁱ = RainSinkExt.rain_sink_accretion(process.cloud_ice_rain_accretion, rain, parameters.cloud.ice,
                                             rain_velocity, qᶜⁱ, qʳ, ρᵢ)
    S = Sᵃᶜᶜʳⁱ + ifelse(Tᵢ < Tᶠ, Sʳˢⁿ, zero(Sʳˢⁿ))

    # Both rates are gated to 0 for qʳ ≤ ε, so x = 0 there
    x = Δt * S / max(qʳ, floatmin(qʳ))
    return ρᵢ * S * x / (1 + x)
end

function add_implicit_rain_sink_correction!(simulation)
    model = simulation.model
    haskey(model.microphysical_fields, :ρqˢⁿ) ||
        error("--implicit_rain_sink supports mixed-phase one-moment microphysics only")
    μ = model.microphysical_fields
    categories = model.microphysics.categories
    ρ = Breeze.AtmosphereModels.total_density(model.dynamics)
    FT = eltype(model.grid)
    δ = CenterField(model.grid)   # storage reused every stage; Δt changes, so the operation is rebuilt

    function correct_rain_sink!(model)
        correction = KernelFunctionOperation{Center, Center, Center}(
            implicit_rain_sink_correction, model.grid, ρ, model.temperature, μ.ρqʳ, μ.ρqˢⁿ, μ.ρqᶜⁱ,
            categories.parameters, categories.freezing_temperature, FT(simulation.Δt))
        compute!(Field(correction; data = δ.data))
        interior(model.timestepper.Gⁿ.ρqʳ) .+= interior(δ)
        interior(model.timestepper.Gⁿ.ρqˢⁿ) .-= interior(δ)
        return nothing
    end

    add_callback!(simulation, correct_rain_sink!; callsite = TendencyCallsite())
    return nothing
end
