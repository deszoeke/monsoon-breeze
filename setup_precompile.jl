# Precompile MonsoonConvection, including its CPU warm-up run, and check that it loads.
#
#     julia --project setup_precompile.jl
#
# Run it once after installing, and again after `git pull`, package updates or edits to
# MonsoonConvection/src. It is the same everywhere (laptop, GPU node): the precompiled code is
# hardware-independent, and GPU jobs compile their GPU-specific code at startup. To check a GPU
# node, use check_gpu.jl.
#
#   - Needs about 6 GB of memory. On HPC, run it on a compute node (srun --mem=32G ...), not on a
#     login node, whose per-user memory limit is usually lower.
#   - Never compiles CUDA.jl: CPU runs don't load it, and compiling it on a node without an
#     NVIDIA driver breaks CUDA on the GPU nodes later (see README, Troubleshooting).
#   - Ends with a load check in a fresh Julia process and exits with an error if loading fails.
#     Pkg reports some failures only as "✗" without failing, so its summary is not trusted.
#
# Compiled code is cached per CPU type, so the laptop and cluster nodes keep separate caches.

if !isempty(ARGS)
    println(stderr, "ERROR: setup_precompile.jl takes no arguments (got: $(join(ARGS, ' '))).")
    any(startswith("--arch"), ARGS) &&
        println(stderr, "--arch is no longer needed: precompilation is the same for CPU and GPU runs. " *
                        "To check a GPU node, run: julia --project check_gpu.jl")
    exit(1)
end

using Pkg

println("""
CPU:              $(Sys.CPU_NAME)
JULIA_CPU_TARGET: $(get(ENV, "JULIA_CPU_TARGET", "(unset, native CPU; recommended)"))
Memory:           $(round(Sys.total_memory() / 2^30, digits=1)) GiB total on this node; precompiling needs about 6 GB
""")

# Precompile only what a run loads; never CUDA (see header).
Pkg.precompile(["MonsoonConvection", "Oceananigans"])

# Load check in a fresh process: prints the full error of anything that failed and sets the
# exit status, independently of Pkg's summary.
println("\nLoad check: loading MonsoonConvection in a fresh process...")
load_ok = success(pipeline(`$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) -e "using MonsoonConvection"`;
                           stdout, stderr))
println(load_ok ? "Load check: ok" : "Load check: FAILED (error above)")
load_ok || exit(1)
