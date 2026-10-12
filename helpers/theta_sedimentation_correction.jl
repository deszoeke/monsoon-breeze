# Correct the liquid-ice potential temperature for hydrometeor sedimentation. Included by
# monsoon_convection.jl with --theta_sedimentation_fix; not run directly. From a colleague's
# one-moment patch, extended to P3.
#
# Why: Breeze diagnoses T = Π θˡⁱ + (ℒˡ qˡ + ℒⁱ qⁱ) / cᵖᵐ, but its ρθ tendency has no sedimentation
# term. When condensate falls, qˡ and qⁱ change at fixed θˡⁱ, so T changes by ℒ Δq / cᵖᵐ: cells
# where condensate collects warm and cells it falls out of cool. Summed over a column, this removes
# ℒ × (surface precipitation) of energy, undoing the latent heating of the condensate that rains
# out (see breeze_issue_theta_sedimentation.md).
#
# How: a TendencyCallsite callback adds to Gρθ, at each RK stage, the term that keeps T fixed,
#     Δ(ρθ) = −(ℒˡ Sˡ + ℒⁱ Sⁱ) / (cᵖᵐ Π),
# where Sˡ and Sⁱ are the sedimentation convergences of all liquid and all ice species
# (sedimenting_species below). Π and cᵖᵐ are Breeze's, from the reference pressure and the current
# moisture. The fluxes are first-order upwind, whereas Breeze sediments with the model's WENO
# scheme, so the correction cancels the leak only to that accuracy.

using Breeze, Oceananigans
using Breeze.Thermodynamics: MoistureMassFractions, mixture_gas_constant, mixture_heat_capacity
using Oceananigans: TendencyCallsite
using Oceananigans.Operators: Δzᶜᶜᶜ

# Downward sedimentation flux through face k, upwind from the cell above (w < 0 falling).
# The fall velocities live at z-faces; w at the surface face carries precipitation out.
@inline sedimentation_flux(i, j, k, ρq, w) = @inbounds ρq[i, j, k] * w[i, j, k]

# Sedimentation convergence of ρq in cell k (kg m⁻³ s⁻¹); nothing falls in through the top
@inline function sedimentation_convergence(i, j, k, grid, ρq, w)
    F₋ = sedimentation_flux(i, j, k, ρq, w)
    F₊ = ifelse(k == grid.Nz, zero(F₋), sedimentation_flux(i, j, k + 1, ρq, w))
    return -(F₊ - F₋) / Δzᶜᶜᶜ(i, j, k, grid)
end

# Sums over tuples of (ρq, w) pairs and of q fields, unrolled for GPU kernels
@inline total_convergence(i, j, k, grid, ::Tuple{}) = 0
@inline total_convergence(i, j, k, grid, species::Tuple) =
    sedimentation_convergence(i, j, k, grid, species[1]...) + total_convergence(i, j, k, grid, Base.tail(species))

@inline total(i, j, k, ::Tuple{}) = 0
@inline total(i, j, k, q::Tuple) = @inbounds q[1][i, j, k] + total(i, j, k, Base.tail(q))

@inline function θ_sedimentation_correction(i, j, k, grid, liquid, ice, qᵛ, qˡ, qⁱ, pᵣ, pˢᵗ, constants)
    Sˡ = total_convergence(i, j, k, grid, liquid)
    Sⁱ = total_convergence(i, j, k, grid, ice)

    q = @inbounds MoistureMassFractions(qᵛ[i, j, k], total(i, j, k, qˡ), total(i, j, k, qⁱ))
    cᵖᵐ = mixture_heat_capacity(q, constants)
    Π = @inbounds (pᵣ[i, j, k] / pˢᵗ)^(mixture_gas_constant(q, constants) / cᵖᵐ)

    ℒˡ = constants.liquid.reference_latent_heat
    ℒⁱ = constants.ice.reference_latent_heat
    return -(ℒˡ * Sˡ + ℒⁱ * Sⁱ) / (cᵖᵐ * Π)
end

"""
Liquid and ice (ρq, w) pairs that sediment, and the specific-humidity fields that make up qˡ
and qⁱ, for the model's microphysics:
- one-moment (mixed phase): liquid = cloud liquid, rain; ice = cloud ice, snow.
- P3: liquid = cloud liquid, rain, liquid on ice (which falls with the ice); ice = ice (rime is
  part of ρqⁱ, so it isn't counted again).
"""
function sedimentation_species(μ)
    if haskey(μ, :ρqˢⁿ)        # one-moment, mixed phase
        liquid = ((μ.ρqᶜˡ, μ.wᶜˡ), (μ.ρqʳ, μ.wʳ))
        ice    = ((μ.ρqᶜⁱ, μ.wᶜⁱ), (μ.ρqˢⁿ, μ.wˢⁿ))
        qˡ, qⁱ = (μ.qᶜˡ, μ.qʳ), (μ.qᶜⁱ, μ.qˢⁿ)
    elseif haskey(μ, :ρqʷⁱ)    # P3
        liquid = ((μ.ρqᶜˡ, μ.wᶜˡ), (μ.ρqʳ, μ.wʳ), (μ.ρqʷⁱ, μ.wⁱ))
        ice    = ((μ.ρqⁱ, μ.wⁱ),)
        qˡ, qⁱ = (μ.qᶜˡ, μ.qʳ, μ.qʷⁱ), (μ.qⁱ,)
    else
        error("--theta_sedimentation_fix supports mixed-phase one-moment and P3 microphysics only")
    end
    return liquid, ice, qˡ, qⁱ
end

function add_theta_sedimentation_correction!(simulation)
    model = simulation.model
    μ = model.microphysical_fields
    liquid, ice, qˡ, qⁱ = sedimentation_species(μ)
    reference_state = model.dynamics.reference_state
    correction = Field(KernelFunctionOperation{Center, Center, Center}(
        θ_sedimentation_correction, model.grid, liquid, ice, μ.qᵛ, qˡ, qⁱ,
        reference_state.pressure, reference_state.standard_pressure, model.thermodynamic_constants))

    function correct_θ_tendency!(model)
        compute!(correction)
        interior(model.timestepper.Gⁿ.ρθ) .+= interior(correction)
        return nothing
    end

    add_callback!(simulation, correct_θ_tendency!; callsite = TendencyCallsite())
    return correction
end
