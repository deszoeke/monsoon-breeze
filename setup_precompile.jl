# Precompile MonsoonConvection (including its CPU warm-up run) and check that it loads.
#
#     julia --project setup_precompile.jl
#
# Run after installing, `git pull`, package updates or edits to MonsoonConvection/src.
# Needs ~6 GB of memory: on HPC submit `sbatch precompile_job.sh` (or run it in an srun session
# with --mem=32G), not on the login node.
# It never compiles CUDA, and ends with a load check in a fresh process that sets the exit
# status (Pkg can report a failure as "✗" and still succeed).

isempty(ARGS) || (println(stderr, "setup_precompile.jl takes no arguments"); exit(1))

using Pkg

println("CPU $(Sys.CPU_NAME), $(round(Int, Sys.total_memory() / 2^30)) GiB memory, ",
        "JULIA_CPU_TARGET=", get(ENV, "JULIA_CPU_TARGET", "(native)"))

Pkg.precompile(["MonsoonConvection", "Oceananigans"])

project = dirname(Base.active_project())
if success(pipeline(`$(Base.julia_cmd()) --project=$project -e "using MonsoonConvection"`; stdout, stderr))
    println("Load check: ok")
else
    println("Load check: FAILED (error above)")
    exit(1)
end
