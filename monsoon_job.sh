#!/bin/bash
# Slurm batch job for the Breeze monsoon-convection run on a GPU node (partition ceoas-gpu).
#
# Output and checkpoints go to the run directory RUN, by default run/ in the repository
# (git-ignored). Submit from anywhere; the Slurm log slurm-<jobid>.out is written to the
# directory you submit from:
#
#   cd ~/monsoon-breeze
#   sbatch monsoon_job.sh                  # first job
#   sbatch monsoon_job.sh --restart        # each continuation job
#
#   # or chain a continuation behind the first job:
#   jid=$(sbatch --parsable monsoon_job.sh)
#   sbatch --dependency=afterok:$jid monsoon_job.sh --restart
#
# A restart resumes from the latest checkpoint in RUN, so use a separate RUN for each
# experiment, e.g.  RUN=$HOME/monsoon-breeze/run/sst302 sbatch monsoon_job.sh
# (On HPC, RUN may also point to a scratch filesystem if the repository's disk is small.)
#
# Arguments after the script name are passed to monsoon_convection.jl (e.g. --restart,
# --stop_time=96h, --float=Float64). See the README, "HPC setup", before the first run:
# check the partition's GPU request syntax and limits, and precompile with
#   julia --project setup_precompile.jl --arch=gpu
# on a GPU node.

#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-gpu
#SBATCH --gres=gpu:1               # or --gres=gpu:<type>:1, or --gpus=1 (see README step 0)
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G                  # host memory; output is staged on the host before writing
#SBATCH --time=48:00:00            # within the partition limit (sinfo -p ceoas-gpu -o %l)
#SBATCH --output=slurm-%j.out

set -euo pipefail

# Repository location (override at submission: REPO=/other/path sbatch monsoon_job.sh)
REPO=${REPO:-$HOME/monsoon-breeze}

# Run directory for output and checkpoints (one per experiment)
RUN=${RUN:-$REPO/run}

# Real-time limit for the model: stop and checkpoint about 1 h before the Slurm --time limit,
# leaving room for startup (CUDA kernel compilation) and the final checkpoint write.
WALL_TIME=${WALL_TIME:-47h}

# Julia environment: use the same values as when precompiling (see README), e.g.
# export JULIA_DEPOT_PATH=/path/to/shared/julia_depot
# export JULIA_CPU_TARGET="generic;skylake-avx512,clone_all;znver3,clone_all"

mkdir -p "$RUN"
cd "$RUN"

echo "job $SLURM_JOB_ID on $(hostname) at $(date)"
echo "run directory: $PWD"
echo "repository:    $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
echo "arguments:     --arch=gpu --wall_time=$WALL_TIME $*"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
julia --version

srun julia --project="$REPO" "$REPO/monsoon_convection.jl" --arch=gpu --wall_time="$WALL_TIME" "$@"

echo "finished at $(date)"
