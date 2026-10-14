# Workflow cheat sheet

Full details are in `README.md`; this is the short version.

## Conventions

- Each run directory holds its own copy of `monsoon_convection.jl`; the settings block at the top
  of the copy (Julia assignments) is the run's whole configuration. No command-line flags.
- Hardware is requested (`arch = :gpu`), never auto-detected; a failed check halts before
  touching caches.
- Experiments go in the driver copy, not in the `MonsoonConvection` package. Editing the package
  means re-precompiling (on each architecture).
- `helpers/arch_env.sh` sets juliaup, the depot, `JULIA_CPU_TARGET` and the Slurm commands by
  `uname -m`; the job scripts source it, and `~/.bashrc` should too.
- Commit and push only when asked.

## Laptop (CPU)

```sh
julia --project setup_precompile.jl                    # after any package change (~2 min)
mkdir -p run/small_test && cp monsoon_convection.jl run/small_test/   # set arch = :cpu, small_test = true
cd run/small_test && julia --project=../.. monsoon_convection.jl
```
I use the release version of julia (1.13.1) from juliaup.

For reference, Julia 1.12.2 binaries are at 
`/local/ceoas/x86_64/opt/julia/julia-1.12.2/bin/julia` and 
`/local/ceoas/aarch64/opt/julia/julia-1.12.2/bin/julia`, 
with the corresponding library paths at 
`/local/ceoas/x86_64/opt/julia/julia-1.12.2/lib` and 
`/local/ceoas/aarch64/opt/julia/julia-1.12.2/lib`. 

## Cluster

```sh
git pull && sbatch -p ceoas precompile_job.sh          # after package changes, per architecture (-p ceoas-arm); wait for it
srun -p ceoas-arm --gres=gpu:gh200_480gb:1 --mem=32G --time=1:00:00 --pty bash   # interactive GPU
julia --project check_gpu.jl                           # stages 1–3; --smoke_test adds a 10 min run

# new experiment, or a restart from another run's checkpoint in a fresh directory
mkdir -p run/exp && cp monsoon_convection.jl run/exp/  # edit the copy's settings
cp run/one-moment/monsoon_convection_checkpoint_iteration<N>.jld2 run/exp/   # + restart = true
sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp   # partitions: monsoon_job.sh header
```

The job log is `<run directory>/slurm-<job>.out`, next to the run's output, and starts with the
copy's settings; the `slurm-<job>.out` in the repository only names the run directory. Logs from
before 2026-10-11 are all in the repository: `grep -H "run directory" slurm-*.out` tells which run
each belongs to. `sacct -j <job> -o SubmitLine%200` shows past submissions.

## Settings (top of each run's monsoon_convection.jl)

Run: `arch small_test restart stop_time (total) checkpoint_interval debug_nan`.
Model: `float_type microphysics sponge_variables sponge_timescale`.
Fixes to Breeze, on by default: `theta_sedimentation_fix pressure_solver_type (Float64)
implicit_rain_sink`. Stability, on by default and not yet tested off: `sedimentation_cfl
bounded_advection`.

## Julia lessons from this project

Compiling
- The compiled code depends on types, not values. Pass Vector{Float64}, not ranges or
  functions, into the package (a range is a new type and triggers a new compile).
- A package can't redefine another package's methods while precompiling. Do such overrides at
  run time with `include` (e.g. helpers/pressure_solver_precision.jl); use
  `Base.invokelatest` to call what the include defined.
- Pkg.precompile can fail silently. Check by loading the package in a fresh process
  (setup_precompile.jl does this).
- Don't precompile GPU code; GPU jobs compile at startup. Precompile on a compute node, not
  the login node (memory), and pin the CUDA runtime (`CUDA.set_runtime_version!`).
- The first time step of a run compiles; time the second step.

Oceananigans/Breeze usage
- Set `Oceananigans.defaults.FloatType` before building anything.
- Mixed number types in parameter tuples are rejected (WENO bounds): `map(FT, bounds)`.
- `Array(interior(f))` copies the whole field to the host, which is slow on the full domain.
  For diagnostics, reduce on the GPU: `Field(Reduction(maximum!, op, dims=(1, 2)))`, with
  `KernelFunctionOperation` for custom expressions (see sedimentation_rate_profile).
- Build objects that hold lookup tables on the target architecture (`on_architecture(arch, …)`).

Finding things
- `pkgdir(Pkg)`, `pkgversion(Pkg)`: where the source is and which version is loaded.
- `@which f(args...)`: the method that will actually run, with file and line.
- Code graphs: helpers/graph_package.sh (see CLAUDE.md).

Scripts
- Top-level loops in a script assign to globals (soft-scope warnings); wrap them in `let` or
  a function.
- GPU errors can be thousands of lines (a non-isbits argument lists every field); the driver
  prints the first 40 lines and saves the rest to error.log.
