module MonsoonConvectionCUDAExt

# GPU precompile warm-up run, enabled only when the user has *requested* GPU precompilation
# with `julia --project setup_precompile.jl --arch=gpu`, which checks that a GPU is available
# before setting the `precompile_gpu` preference (in LocalPreferences.toml).
#
# The preference belongs to MonsoonConvection but is read (and recorded as a compile-time
# preference) only here, so changing it invalidates this extension's cache and not the
# base package's CPU cache.

using MonsoonConvection
using CUDA
using Oceananigans
using PrecompileTools
using Preferences

const package_uuid = Base.PkgId(MonsoonConvection).uuid
const precompile_gpu = Preferences.load_preference(package_uuid, "precompile_gpu", false)
Base.record_compiletime_preference(package_uuid, "precompile_gpu")

if precompile_gpu
    @setup_workload begin
        CUDA.functional() || error("MonsoonConvection preference precompile_gpu = true, but CUDA is not " *
                                   "functional here. Precompile on a GPU node, or run " *
                                   "`julia --project setup_precompile.jl --arch=cpu`.")
        @compile_workload begin
            FT = Oceananigans.defaults.FloatType
            Oceananigans.defaults.FloatType = Float32
            try
                MonsoonConvection.run_workload(GPU())
            finally
                Oceananigans.defaults.FloatType = FT
            end
        end
    end
end

end # module
