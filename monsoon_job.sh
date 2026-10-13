#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --time=48:00:00
#SBATCH --output=slurm-%j.out

# Breeze monsoon-convection run on one A100 GPU (partition ceoas-gpu).
#
# Submit from the repository directory; arguments go to monsoon_convection.jl:
#   sbatch monsoon_job.sh                      # first job
#   sbatch monsoon_job.sh --restart            # continuation, until the stop time is reached
#   RUN=run/sst302 sbatch monsoon_job.sh       # another experiment in its own run directory
# Output, checkpoints and the log (slurm-<jobid>.out) go to $RUN (default run/). The
# slurm-<jobid>.out in the repository only says where the run directory is.

set -euo pipefail

export PATH="$HOME/.juliaup/bin:$PATH"     # juliaup's Julia 1.13, not the system julia
REPO=$SLURM_SUBMIT_DIR
RUN=${RUN:-run}
WALL_TIME=${WALL_TIME:-47h}                # stop and checkpoint 1 h before --time

# Slurm gives the job one GPU of its own, but processes started outside Slurm can still be on it.
# Stop at once if they leave too little memory for the run (estimated 10–20 GB; check nvidia-smi on a running job).
: "${CUDA_VISIBLE_DEVICES:?no GPU allocated to this job}"
gpu=$CUDA_VISIBLE_DEVICES
free=$(nvidia-smi -i "$gpu" --query-gpu=memory.free --format=csv,noheader,nounits)
(( free >= 40000 )) || { echo "GPU $gpu has only $free MiB free" >&2; exit 1; }

mkdir -p "$RUN" && cd "$RUN"
echo "job $SLURM_JOB_ID on $(hostname), GPU $gpu ($free MiB free), $(julia --version), run directory $PWD"

# The rest of the log goes in the run directory, next to the run's output and checkpoints
# (#SBATCH --output can't use $RUN). slurm-<jobid>.out in the repository keeps the line above.
LOG=$PWD/slurm-$SLURM_JOB_ID.out
echo "log: $LOG"
exec > "$LOG" 2>&1
echo "job $SLURM_JOB_ID on $(hostname), GPU $gpu ($free MiB free), $(julia --version), run directory $PWD"

# srun --unbuffered writes output to the log as it comes, so the --debug_nan diagnostics just before
# a crash are not lost in a buffer. Slurm sets CUDA_VISIBLE_DEVICES again for the job step, so
# env sets the allocated GPU once more inside the step.
cmd=(julia --project="$REPO" "$REPO/monsoon_convection.jl" --arch=gpu --wall_time="$WALL_TIME" "$@")
echo "command: ${cmd[*]}"
srun --unbuffered env CUDA_VISIBLE_DEVICES="$gpu" "${cmd[@]}"
