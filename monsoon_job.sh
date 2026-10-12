#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-gpu
#SBATCH --gres=gpu:a100:2         # 2 A100s, the run uses one idle one (see below); back to
                                  # gpu:a100:1 when aerosmith's GPU 2 is no longer in use
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

# Run on the first allocated GPU that is idle (Slurm keeps assigning aerosmith's busy GPU 2).
: "${CUDA_VISIBLE_DEVICES:?no GPU allocated to this job}"
for gpu in ${CUDA_VISIBLE_DEVICES//,/ }; do
    used=$(nvidia-smi -i "$gpu" --query-gpu=memory.used --format=csv,noheader,nounits)
    (( used < 1024 )) && break
done
(( used < 1024 )) || { echo "all allocated GPUs ($CUDA_VISIBLE_DEVICES) are busy" >&2; exit 1; }
export CUDA_VISIBLE_DEVICES=$gpu

mkdir -p "$RUN" && cd "$RUN"
echo "job $SLURM_JOB_ID on $(hostname), GPU $gpu, $(julia --version), run directory $PWD"

# The rest of the log goes in the run directory, next to the run's output and checkpoints
# (#SBATCH --output can't use $RUN). slurm-<jobid>.out in the repository keeps the line above.
LOG=$PWD/slurm-$SLURM_JOB_ID.out
echo "log: $LOG"
exec > "$LOG" 2>&1
echo "job $SLURM_JOB_ID on $(hostname), GPU $gpu, $(julia --version), run directory $PWD"

# srun --unbuffered writes output to the log as it comes, so the --debug_nan diagnostics just before
# a crash are not lost in a buffer. Slurm sets CUDA_VISIBLE_DEVICES again for the job step, so
# env sets the idle GPU chosen above once more inside the step.
cmd=(julia --project="$REPO" "$REPO/monsoon_convection.jl" --arch=gpu --wall_time="$WALL_TIME" "$@")
echo "command: ${cmd[*]}"
srun --unbuffered env CUDA_VISIBLE_DEVICES="$gpu" "${cmd[@]}"
