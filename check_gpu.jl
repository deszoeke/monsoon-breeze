# Check that this GPU node can run the model. Stops at the first failed stage with the real
# error and exit status 1; writes nothing to the repository.
#
#     julia --project check_gpu.jl                # stages 1–3, a few minutes
#     julia --project check_gpu.jl --smoke_test   # adds stage 4, about 10 more minutes
#     julia --project check_gpu.jl --cpu          # stages 3–4 on CPU (tests this script without a GPU)
#
#   1  CUDA works (NVIDIA GPU present, CUDA functional)
#   2  a CUDA context opens on the allocated GPU (fails if it is busy or not yours); a trivial kernel
#   3  the 32×16×65 model builds and takes two time steps in Float32 (first step compiles the GPU code)
#   4  monsoon_convection.jl --small_test runs 10 simulated minutes, with output and checkpoint

using Printf
include(joinpath(@__DIR__, "helpers", "preflight.jl"))

flags = try
    parse_flags(ARGS, ("smoke_test", "cpu"))
catch err
    println(stderr, "ERROR: ", sprint(showerror, err)); exit(1)
end
on_cpu = haskey(flags, "cpu")

"Run `f` as a named stage; on error print it and exit 1."
function stage(f, name)
    println("\n== ", name)
    t = @elapsed try
        f()
    catch err
        showerror(stderr, err); println(stderr)
        println("== FAIL: ", name); exit(1)
    end
    @printf("== PASS: %s (%.1f s)\n", name, t)
end

on_cpu || stage(require_gpu, "1. CUDA works")

on_cpu || stage("2. CUDA context and kernel on GPU $(get(ENV, "CUDA_VISIBLE_DEVICES", "?"))") do
    try
        CUDA.context()
    catch err
        error(sprint(showerror, err), "\nThe GPU is busy or not allocated to you: check `nvidia-smi` ",
              "and `echo \$CUDA_VISIBLE_DEVICES` inside your srun/sbatch allocation.")
    end
    @printf("%s, %.1f of %.1f GiB free\n", CUDA.name(CUDA.device()),
            CUDA.CUDACore.free_memory() / 2^30, CUDA.CUDACore.total_memory() / 2^30)
    sum(CUDA.ones(Float32, 1024)) == 1024 || error("trivial kernel gave a wrong result")
end

using Oceananigans
using Oceananigans.TimeSteppers: time_step!
Oceananigans.defaults.FloatType = Float32
using MonsoonConvection

stage("3. model builds and steps on $(on_cpu ? "CPU" : "GPU")") do
    sounding = read_cm1_sounding(joinpath(@__DIR__, "cm1", "input_sounding"))
    model = build_model(sounding; arch = on_cpu ? CPU() : GPU(), Nx = 32, Ny = 16)
    set_initial_conditions!(model, sounding)
    t1 = @elapsed time_step!(model, 1)
    t2 = @elapsed time_step!(model, 1)
    wmax = maximum(abs, model.velocities.w)
    isfinite(wmax) || error("non-finite w after two steps")
    @printf("first step %.1f s (compiles), second step %.3f s, max|w| = %.1e m/s\n", t1, t2, wmax)
end

haskey(flags, "smoke_test") && stage("4. smoke test: 10 simulated minutes with output") do
    driver = joinpath(@__DIR__, "monsoon_convection.jl")
    mktempdir() do dir
        cmd = `$(Base.julia_cmd()) --project=$(@__DIR__) $driver --arch=$(on_cpu ? "cpu" : "gpu") --small_test --stop_time=10min`
        success(pipeline(Cmd(cmd; dir); stdout, stderr)) || error("monsoon_convection.jl failed (output above)")
        println("output files: ", join(readdir(dir), ", "))
    end
end

println("\nAll checks passed", on_cpu ? " (on CPU; no GPU was tested)." : ".")
