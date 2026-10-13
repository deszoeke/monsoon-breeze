#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-arm     # rime, youmu (ceoas-arm-lowprio requeues preempted jobs, from t = 0 without --restart)
#SBATCH --gres=gpu:gh200_480gb:1
#SBATCH --cpus-per-task=2         # the run is GPU-bound
#SBATCH --mem=32G                 # Julia, compilation, checkpoint writing
#SBATCH --time=02:00:00           # short diagnostic runs; for long ones pass e.g. sbatch --time=48:00:00
#SBATCH --output=slurm-%j.out

# The monsoon-convection run on a Grace Hopper GH200 (aarch64 CPU, 480 GB GPU). Same use as
# monsoon_job.sh, which does the work and picks the aarch64 Julia and depot:
#   RUN=run/one-moment sbatch monsoon_job_arm.sh --restart ...
# Needs Julia 1.13 in ~/.juliaup-aarch64 and the project instantiated in ~/.julia-aarch64, both
# done on an ARM node.

# Slurm runs a copy of this script, so find monsoon_job.sh in the submit directory
source "$SLURM_SUBMIT_DIR/monsoon_job.sh"
