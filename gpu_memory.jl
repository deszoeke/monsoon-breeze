# Measure the model's GPU memory at a few grid sizes and extrapolate to the production grid.
# Writes nothing to disk.
#
#     CUDA_VISIBLE_DEVICES=2 julia --project gpu_memory.jl     # pick a free GPU (nvidia-smi)
#
# For each grid size the model is built in the production precision (Float32, Float64 pressure
# solve), initialised from the sounding and stepped twice (the first step compiles), and the
# script prints:
#   resident  device memory held while the model exists (fields, solver, radiation)
#   peak      memory held after the steps, before freeing temporaries; what must fit on the card
#   step      wall time of the second step
# Memory is the drop in the device's free memory, so other processes on the same GPU should not
# start or stop during the run. Sizes run smallest first and the script stops at the first
# out-of-memory error. A linear fit (fixed + per-cell) then predicts the production grid.
#
# Vertical grid: build_model's default CM1 levels (65), slightly more than the driver's
# stretched top (58), so the per-cell figure is a little conservative for the top.
#
# Pascal GPUs (GTX 1080 Ti, compute capability 6.1): CUDA 13 dropped them, so if CUDA is not
# functional pin a 12.x runtime in this machine's LocalPreferences.toml (not committed):
#     julia --project -e 'using CUDA; CUDA.set_runtime_version!(v"12.6")'
# and ignore require_gpu's suggestion to pin the driver's version (13.0).

using Printf

#####
##### Settings
#####

sizes      = [(32, 16), (128, 64), (256, 128), (512, 256)]   # (Nx, Ny), smallest first
production = (1024, 512, 58)                                 # (Nx, Ny, Nz) to extrapolate to

#####
##### Setup
#####

include(joinpath(@__DIR__, "helpers", "preflight.jl"))
require_gpu()

using Oceananigans
using Oceananigans.TimeSteppers: time_step!
Oceananigans.defaults.FloatType = Float32
include(joinpath(@__DIR__, "helpers", "pressure_solver_precision.jl"))   # Float64 pressure solve
using MonsoonConvection

const GiB = 2^30
free_memory() = (CUDA.synchronize(); CUDA.CUDACore.free_memory())

"Release everything unreferenced so the device's free memory is back to its baseline."
function release!()
    GC.gc(true)
    CUDA.reclaim()
    return nothing
end

"Build and step the model at Nx × Ny; return (cells, resident bytes, peak bytes, step seconds)."
function measure(sounding, Nx, Ny, baseline)
    model = build_model(sounding; arch = GPU(), Nx, Ny)
    set_initial_conditions!(model, sounding)
    time_step!(model, 1)                     # compiles
    step = @elapsed (time_step!(model, 1); CUDA.synchronize())
    peak = baseline - free_memory()          # pool still holds the steps' temporaries
    GC.gc(true); CUDA.reclaim()              # drops temporaries, keeps the model
    resident = baseline - free_memory()
    isfinite(maximum(abs, model.velocities.w)) || @warn "non-finite w at $(Nx)×$(Ny)"
    return prod(size(model.grid)), resident, peak, step
end

CUDA.context()
@printf("%s: %.1f of %.1f GiB free\n\n", CUDA.name(CUDA.device()),
        free_memory() / GiB, CUDA.CUDACore.total_memory() / GiB)

sounding = read_cm1_sounding(joinpath(@__DIR__, "cm1", "input_sounding"))

@printf("%-14s %12s %12s %12s %10s\n", "grid", "cells", "resident GiB", "peak GiB", "step s")
results = Tuple{Int, Int, Int}[]   # (cells, resident, peak)
for (Nx, Ny) in sizes
    release!()
    baseline = free_memory()
    try
        cells, resident, peak, step = measure(sounding, Nx, Ny, baseline)
        push!(results, (cells, resident, peak))
        @printf("%-14s %12d %12.2f %12.2f %10.3f\n", "$(Nx)×$(Ny)×$(cells ÷ (Nx * Ny))",
                cells, resident / GiB, peak / GiB, step)
    catch err
        err isa CUDA.OutOfGPUMemoryError || rethrow()
        println("$(Nx)×$(Ny): out of GPU memory; stopping")
        break
    end
end

#####
##### Linear fit, memory = fixed + per_cell × cells, and the production grid
#####

if length(results) ≥ 2
    N = Float64[r[1] for r in results]
    A = hcat(ones(length(N)), N)
    total = CUDA.CUDACore.total_memory()
    target = prod(production)
    println()
    for (label, column) in (("resident", 2), ("peak", 3))
        fixed, per_cell = A \ Float64[r[column] for r in results]
        predicted = fixed + per_cell * target
        @printf("%-8s %6.0f bytes/cell + %5.2f GiB fixed → %s: %.1f GiB (%.0f%% of this card)\n",
                label, per_cell, fixed / GiB, join(production, "×"), predicted / GiB,
                100predicted / total)
    end
else
    println("\nFewer than two sizes ran; no fit.")
end
