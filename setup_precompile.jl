# Request the hardware that MonsoonConvection's precompile cache should target, then precompile.
#
#     julia --project setup_precompile.jl --arch=cpu   # CPU warm-up run only (laptop, CPU nodes)
#     julia --project setup_precompile.jl --arch=gpu   # CPU + GPU warm-up runs (on a GPU node)
#
# Order of operations:
#   1. parse the request (--arch=cpu|gpu is required; no auto-detection)
#   2. lightweight hardware check (preflight.jl); halt if the hardware is missing,
#      before anything is written or precompiled
#   3. compare the request with the current `precompile_gpu` preference (LocalPreferences.toml)
#   4. write the preference only if it changed, then precompile (cpu: only what CPU runs
#      load, never CUDA; gpu: everything)
#      (a no-op when nothing changed, so an existing cache is never needlessly rebuilt)
#
# The `precompile_gpu` preference is read only by MonsoonConvectionCUDAExt, so switching
# between cpu and gpu recompiles only that extension, never the base package's CPU cache.
#
# Precompile caches are keyed by CPU type, so a laptop and an HPC node keep separate
# caches automatically. If login and compute nodes differ but share a Julia depot, set e.g.
#     export JULIA_CPU_TARGET="generic;skylake-avx512,clone_all;znver3,clone_all"
# (adjusted to the cluster's CPUs) so that one cache serves all node types.

const usage = "usage: julia --project setup_precompile.jl --arch=cpu|gpu"

include(joinpath(@__DIR__, "preflight.jl"))

request = try
    flags = parse_flags(ARGS, ("arch",))
    haskey(flags, "arch") || error("--arch is required.")
    check_requested_architecture(flags["arch"])
catch err
    println(stderr, "ERROR: ", sprint(showerror, err))
    println(stderr, usage)
    exit(1)
end

using TOML, Preferences, Pkg

package_uuid = Base.UUID(TOML.parsefile(joinpath(@__DIR__, "MonsoonConvection", "Project.toml"))["uuid"])

requested = request == "gpu"
current = Preferences.load_preference(package_uuid, "precompile_gpu", false)
changed = requested != current

changed && Preferences.set_preferences!(package_uuid, "precompile_gpu" => requested; force = true)

println("""
Requested architecture: $request
GPU check:              $(request == "gpu" ? "passed (NVIDIA device present, CUDA functional)" : "not needed")
precompile_gpu:         $requested ($(changed ? "changed" : "unchanged"))
CPU:                    $(Sys.CPU_NAME)
JULIA_CPU_TARGET:       $(get(ENV, "JULIA_CPU_TARGET", "(unset, native)"))
""")

# cpu: precompile only what a CPU run loads. CUDA.jl and MonsoonConvectionCUDAExt are left
# alone: they are never loaded on CPU, and compiling CUDA can fail on nodes without an NVIDIA
# driver (e.g. HPC login nodes).
# gpu: precompile everything, including CUDA and the extension's GPU warm-up run.
if request == "cpu"
    Pkg.precompile(["MonsoonConvection", "Oceananigans"])
else
    Pkg.precompile()
end
