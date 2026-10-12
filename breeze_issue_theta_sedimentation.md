# Liquid-ice potential temperature leaks energy through hydrometeor sedimentation

## Summary

With `LiquidIcePotentialTemperatureFormulation`, the ρθ tendency has no sedimentation term. When
condensate falls, the diagnosed temperature changes by ℒ Δq / cᵖᵐ even though nothing has changed
phase. Cells where condensate collects warm; cells it falls out of cool. Summed over a column,
energy ℒ × (surface precipitation) is lost, which undoes the latent heating of all the condensate
that precipitates out. At 10 mm h⁻¹ this is about 7000 W m⁻². This applies to every scheme that
sediments condensate: P3 and one-moment (found independently by a colleague using one-moment
microphysics with liquid and ice).

## Cause

Breeze v0.11.3:

- `src/Thermodynamics/dynamic_states.jl:68`: T = Π θˡⁱ + (ℒˡᵣ qˡ + ℒⁱᵣ qⁱ) / cᵖᵐ.
- `src/PotentialTemperatureFormulations/potential_temperature_tendency.jl:68`
  (`potential_temperature_tendency`): air advection, closure fluxes, forcing and radiation only.
  The hydrometeors are advected with their fall speeds (`microphysical_velocities`); θˡⁱ is not.

θˡⁱ is conserved under phase changes, but not under sedimentation: falling condensate changes qˡ
and qⁱ at fixed θˡⁱ, and so changes T.

## Size

A 2 g/kg rain layer between 1 and 2 km (P3 fall speed ~7.5 m s⁻¹) gives a spurious
+0.19 K s⁻¹ in the cell below the layer and −0.16 K s⁻¹ in its top cell.

## Fix

Add the sedimentation term to the ρθ tendency. Keeping T fixed when only sedimentation acts gives

    ∂(ρθ)/∂t += −(ℒˡᵣ Sˡ + ℒⁱᵣ Sⁱ) / (cᵖᵐ Π),

where Sˡ and Sⁱ are the sedimentation flux convergences of all liquid and all ice species
(for P3: ρqᶜˡ, ρqʳ, ρqʷⁱ as liquid and ρqⁱ as ice). Ideally S comes from the same discrete fluxes
the scalar transport uses (the advection scheme applied with the fall velocities), so that the
term cancels the leak exactly. A more complete version would also carry the sensible heat of the
falling condensate.

A workaround that adds the term with first-order upwind fluxes, as a `TendencyCallsite`
callback: <https://github.com/…/monsoon-breeze/blob/main/helpers/theta_sedimentation_correction.jl>.
