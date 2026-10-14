# Retired. Breeze ≥ 0.12 adds the θˡⁱ sedimentation tendency itself (PR #959), so this correction
# would apply it twice. Older run copies of monsoon_convection.jl still include this file when
# theta_sedimentation_fix = true; delete that setting and its include block from the copy.
add_theta_sedimentation_correction!(simulation) =
    error("theta_sedimentation_fix is retired: Breeze ≥ 0.12 corrects θˡⁱ for sedimentation. " *
          "Remove theta_sedimentation_fix and its include block from this run's monsoon_convection.jl.")
