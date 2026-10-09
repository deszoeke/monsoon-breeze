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
