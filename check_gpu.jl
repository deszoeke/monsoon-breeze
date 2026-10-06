# Check that this GPU node can run the model: staged, timed, stops at the first failure with
# the real error and exits with status 1. Nothing is written to the repository or preferences.
#
#     julia --project check_gpu.jl                 # stages 1-2 (a few minutes)
#     julia --project check_gpu.jl --smoke_test    # stages 1-3 (about 10 more minutes)
#
#   Stage 1  CUDA works: NVIDIA device present, CUDA.functional(), a CUDA context on the GPU
#            (fails if the GPU is busy or not allocated to you), versioninfo, a trivial kernel.
#   Stage 2  The model compiles on the GPU: build the 32×16×65 model with arch = GPU() in
#            Float32, initialize, take two time steps (the first compiles every GPU kernel of a
#            time step: dynamics, advection, P3, TKE closure, surface fluxes, RRTMGP radiation).
#   Stage 3  End-to-end smoke test (--smoke_test): run monsoon_convection.jl --arch=gpu
#            --small_test --stop_time=10min in a temporary directory (adds output, NetCDF,
#            checkpointing and the run flags).
#
# Run stages 1-2 after every `git pull` or package update, and stage 3 before the first
# production job. On HPC, inside a GPU allocation, e.g.
#     srun -p ceoas-gpu --gres=gpu:1 --cpus-per-task=4 --mem=32G --time=1:00:00 --pty bash -l
#
# Developer option: --rehearse_on_cpu skips stage 1 and runs stages 2-3 with arch = CPU(), to
# test this script's logic on a machine without a GPU.

using Printf

include(joinpath(@__DIR__, "preflight.jl"))

const usage = "usage: julia --project check_gpu.jl [--smoke_test] [--rehearse_on_cpu]"

flags = try
    parse_flags(ARGS, ("smoke_test", "rehearse_on_cpu"))
catch err
    println(stderr, "ERROR: ", sprint(showerror, err), "\n", usage)
    exit(1)
end
smoke_test = parse_bool("smoke_test", get(flags, "smoke_test", "false"))
rehearse = parse_bool("rehearse_on_cpu", get(flags, "rehearse_on_cpu", "false"))

"Run `f` as a named stage; on any error print it in full and exit 1."
function stage(f, name)
    println("\n== ", name)
    start = time()
    try
        f()
    catch err
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        @printf("== FAIL: %s (after %.1f s)\n", name, time() - start)
        exit(1)
    end
    @printf("== PASS: %s (%.1f s)\n", name, time() - start)
end

#####
##### Stage 1: CUDA works
#####

if rehearse
    println("\n== Stage 1 skipped (--rehearse_on_cpu): stages 2-3 run with arch = CPU()")
else
    stage("Stage 1a: NVIDIA device present and CUDA functional") do
        check_requested_architecture("gpu")      # loads CUDA into Main only after the cheap check
    end

    # CUDA.functional() only checks that the driver and runtime libraries load; it does not
    # touch the GPU. Creating a context does, and fails if the GPU is busy or not ours.
    stage("Stage 1b: create a CUDA context on the allocated GPU") do
        println("SLURM_JOB_ID=", get(ENV, "SLURM_JOB_ID", "(unset)"),
                "  SLURM_JOB_GPUS=", get(ENV, "SLURM_JOB_GPUS", "(unset)"),
                "  CUDA_VISIBLE_DEVICES=", get(ENV, "CUDA_VISIBLE_DEVICES", "(unset)"))
        try
            CUDA.context()
        catch err
            error("could not create a CUDA context on $(CUDA.name(CUDA.device())): " *
                  sprint(showerror, err) * "\n" *
                  "The GPU is most likely in use by another process, or not allocated to this shell.\n" *
                  "  - Run inside a GPU allocation: srun -p ceoas-gpu --gres=gpu:1 ... --pty bash -l\n" *
                  "    (SLURM_JOB_GPUS / CUDA_VISIBLE_DEVICES above should be set).\n" *
                  "  - Check `nvidia-smi` for other processes, and `ps -u \$USER -f | grep julia`\n" *
                  "    for leftover Julia sessions of yours.")
        end
        free, total = CUDA.CUDACore.free_memory(), CUDA.CUDACore.total_memory()
        @printf("GPU: %s, %.1f GiB free of %.1f GiB\n", CUDA.name(CUDA.device()), free / 2^30, total / 2^30)
        free < 1 * 2^30 && @warn "Less than 1 GiB of GPU memory is free; another process may be using this GPU."
    end

    stage("Stage 1c: CUDA versioninfo and a trivial kernel") do
        CUDA.versioninfo()
        s = sum(CUDA.ones(Float32, 1024) .+ 1f0)
        s == 2048 || error("trivial kernel returned $s, expected 2048")
        println("trivial kernel: ok")
    end
end

#####
##### Stage 2: the model compiles and steps on the GPU
#####

println("\n== Stage 2: loading Oceananigans and MonsoonConvection (Float32)")
using Oceananigans
using Oceananigans.TimeSteppers: time_step!
Oceananigans.defaults.FloatType = Float32
using MonsoonConvection

stage("Stage 2: model builds, compiles and takes two time steps on $(rehearse ? "CPU (rehearsal)" : "GPU")") do
    arch = rehearse ? CPU() : GPU()
    println("architecture: ", arch)

    sounding = read_cm1_sounding(joinpath(@__DIR__, "cm1", "input_sounding"))

    t_build = @elapsed model = build_model(sounding; arch, Nx = 32, Ny = 16)
    t_init  = @elapsed set_initial_conditions!(model, sounding)
    t_step1 = @elapsed time_step!(model, 1)
    t_step2 = @elapsed time_step!(model, 1)

    wmax = maximum(abs, model.velocities.w)
    isfinite(wmax) || error("non-finite vertical velocity after two steps (max|w| = $wmax)")

    @printf("build %.1f s, initialize %.1f s, first step (compiles) %.1f s, second step %.3f s, max|w| = %.2e m/s\n",
            t_build, t_init, t_step1, t_step2, wmax)
end

#####
##### Stage 3: end-to-end smoke test of the driver
#####

if smoke_test
    stage("Stage 3: smoke test, monsoon_convection.jl --small_test --stop_time=10min") do
        driver = joinpath(@__DIR__, "monsoon_convection.jl")
        arch_flag = rehearse ? "--arch=cpu" : "--arch=gpu"
        mktempdir() do dir
            cmd = `$(Base.julia_cmd()) --project=$(@__DIR__) $driver $arch_flag --small_test --stop_time=10min`
            success(pipeline(Cmd(cmd; dir); stdout, stderr)) ||
                error("monsoon_convection.jl exited with an error (output above)")
            println("output files: ", join(readdir(dir), ", "))
        end
    end
end

println("\nAll requested checks passed", rehearse ? " (CPU rehearsal; no GPU was tested)." : ".")
