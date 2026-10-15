# Retired. Breeze ≥ 0.12 adds the θˡⁱ sedimentation tendency itself (PR #959), so this correction
# would apply it twice. Run copies of monsoon_convection.jl from before the upgrade still set
# theta_sedimentation_fix = true and include this file; it now does nothing, so they run unchanged.
function add_theta_sedimentation_correction!(simulation)
    @warn "theta_sedimentation_fix is retired and ignored: Breeze ≥ 0.12 corrects θˡⁱ for sedimentation."
    return nothing
end
