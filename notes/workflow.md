# Workflow cheat sheet

Full details are in `README.md`; this is the short version.

## Conventions

- Hardware is requested (`--arch=gpu`), never auto-detected; a failed check halts before
  touching caches.
- Experiments go in the driver (`monsoon_convection.jl`), not in the `MonsoonConvection` package.
  Editing the package means re-precompiling.
- `JULIA_CPU_TARGET="haswell,-rdrnd"` comes from `~/.bashrc` on the cluster; jobs inherit it.
  Don't hardcode it in scripts.
- Commit and push only when asked.

## Laptop (CPU)

```sh
julia --project setup_precompile.jl                    # after any package change (~2 min)
julia --project monsoon_convection.jl --small_test --stop_time=10min --debug_nan
```

## Cluster

```sh
git pull && sbatch precompile_job.sh                   # after package changes; wait for it
srun --partition=ceoas-gpu --gres=gpu:1 --pty bash     # interactive GPU (aerosmith GPU 2 is often busy)
julia --project check_gpu.jl                           # stages 1–3; --smoke_test adds a 10 min run

# restart a run from a checkpoint in a fresh directory
mkdir -p run/sed_cfl
cp run/adv_bounded/monsoon_convection_checkpoint_iteration7699.jld2 run/sed_cfl/
RUN=run/sed_cfl sbatch monsoon_job.sh --restart --debug_nan --sedimentation_cfl --checkpoint_interval=1h
```

`slurm-<job>.out` shows the full command line. `sacct -j <job> -o SubmitLine%200` shows past
submissions.

## Flags (driver)

`--arch --float --pressure_solver --small_test --restart --stop_time (total) --wall_time
--checkpoint_interval --sponge --sponge_timescale --unbounded_advection --sedimentation_cfl
--debug_nan`

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
