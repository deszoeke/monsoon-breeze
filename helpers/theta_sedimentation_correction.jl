# Correct the liquid-ice potential temperature for hydrometeor sedimentation. Included by
# monsoon_convection.jl with --theta_sedimentation_fix; not run directly. Adapted to P3 from a
# colleague's one-moment patch.
#
# Why: Breeze diagnoses T = Π θˡⁱ + (ℒˡ qˡ + ℒⁱ qⁱ) / cᵖᵐ, but its ρθ tendency has no sedimentation
# term. When condensate falls, qˡ and qⁱ change at fixed θˡⁱ, so T changes by ℒ Δq / cᵖᵐ: cells
# where condensate collects warm and cells it falls out of cool. Summed over a column, this removes
# ℒ × (surface precipitation) of energy, undoing the latent heating of the condensate that rains
# out (see breeze_issue_theta_sedimentation.md).
#
# How: a TendencyCallsite callback adds to Gρθ, at each RK stage, the term that keeps T fixed,
#     Δ(ρθ) = −(ℒˡ Sˡ + ℒⁱ Sⁱ) / (cᵖᵐ Π),
# where S is the sedimentation convergence of liquid (cloud, rain, liquid on ice) and of ice
# (rime is part of ρqⁱ, so it isn't counted again). Π and cᵖᵐ are Breeze's, from the reference
# pressure and the current moisture. The fluxes are first-order upwind, whereas Breeze sediments
# with the model's WENO scheme, so the correction cancels the leak only to that accuracy.

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

@inline function θ_sedimentation_correction(i, j, k, grid, μ, pᵣ, pˢᵗ, constants)
    Sˡ = sedimentation_convergence(i, j, k, grid, μ.ρqᶜˡ, μ.wᶜˡ) +
         sedimentation_convergence(i, j, k, grid, μ.ρqʳ,  μ.wʳ)  +
         sedimentation_convergence(i, j, k, grid, μ.ρqʷⁱ, μ.wⁱ)
    Sⁱ = sedimentation_convergence(i, j, k, grid, μ.ρqⁱ,  μ.wⁱ)

    @inbounds q = MoistureMassFractions(μ.qᵛ[i, j, k], μ.qᶜˡ[i, j, k] + μ.qʳ[i, j, k] + μ.qʷⁱ[i, j, k], μ.qⁱ[i, j, k])
    cᵖᵐ = mixture_heat_capacity(q, constants)
    Π = @inbounds (pᵣ[i, j, k] / pˢᵗ)^(mixture_gas_constant(q, constants) / cᵖᵐ)

    ℒˡ = constants.liquid.reference_latent_heat
    ℒⁱ = constants.ice.reference_latent_heat
    return -(ℒˡ * Sˡ + ℒⁱ * Sⁱ) / (cᵖᵐ * Π)
end

function add_theta_sedimentation_correction!(simulation)
    model = simulation.model
    grid = model.grid
    reference_state = model.dynamics.reference_state
    # only the fields the kernel reads (the full set also holds non-Field entries)
    μ = NamedTuple(n => model.microphysical_fields[n]
                   for n in (:ρqᶜˡ, :ρqʳ, :ρqʷⁱ, :ρqⁱ, :wᶜˡ, :wʳ, :wⁱ, :qᵛ, :qᶜˡ, :qʳ, :qʷⁱ, :qⁱ))
    correction = Field(KernelFunctionOperation{Center, Center, Center}(
        θ_sedimentation_correction, grid, μ,
        reference_state.pressure, reference_state.standard_pressure, model.thermodynamic_constants))

    function correct_θ_tendency!(model)
        compute!(correction)
        interior(model.timestepper.Gⁿ.ρθ) .+= interior(correction)
        return nothing
    end

    add_callback!(simulation, correct_θ_tendency!; callsite = TendencyCallsite())
    return correction
end
