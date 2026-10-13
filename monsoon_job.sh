#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --cpus-per-task=2         # the run is GPU-bound
#SBATCH --mem=32G                 # Julia, compilation, checkpoint writing
#SBATCH --time=02:00:00           # short diagnostic runs; for long ones pass e.g. sbatch --time=48:00:00
#SBATCH --output=slurm-%j.out

# Breeze monsoon-convection run on one GPU. Name the partition and GPU when submitting; the script
# assumes no hardware and sets up Julia and Slurm for whatever architecture the job lands on
# (helpers/arch_env.sh). Submit from the repository directory; arguments go to monsoon_convection.jl:
#   A100 (x86_64):    sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh ...
#   GH200 (aarch64):  sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh ...
#   (ceoas-arm-lowprio requeues preempted jobs with their first arguments: from t = 0 without --restart)
# Examples of the arguments:
#   ... monsoon_job.sh                         # first job
#   ... monsoon_job.sh --restart               # continuation, until the stop time is reached
#   RUN=run/sst302 sbatch ...                  # another experiment in its own run directory
# Output, checkpoints and the log (slurm-<jobid>.out) go to $RUN (default run/). The
# slurm-<jobid>.out in the repository only says where the run directory is.

set -euo pipefail

source "$SLURM_SUBMIT_DIR/helpers/arch_env.sh"   # juliaup's Julia 1.13 and Slurm's srun for this architecture
REPO=$SLURM_SUBMIT_DIR
RUN=${RUN:-run}
# Stop and checkpoint 10 min before the job's time limit (whatever --time it was given), unless
# WALL_TIME is set. Slurm gives the job's start and end in seconds since 1970.
limit_min=$(( (SLURM_JOB_END_TIME - SLURM_JOB_START_TIME) / 60 ))
WALL_TIME=${WALL_TIME:-$(( limit_min - 10 ))min}

# Slurm gives the job one GPU of its own, but processes started outside Slurm can still be on it.
# Stop at once if they leave too little memory for the run (estimated 10–20 GB; check nvidia-smi on a running job).
: "${CUDA_VISIBLE_DEVICES:?no GPU allocated to this job}"
gpu=$CUDA_VISIBLE_DEVICES
free=$(nvidia-smi -i "$gpu" --query-gpu=memory.free --format=csv,noheader,nounits)
(( free >= 40000 )) || { echo "GPU $gpu has only $free MiB free" >&2; exit 1; }

mkdir -p "$RUN" && cd "$RUN"
echo "job $SLURM_JOB_ID on $(hostname) ($(uname -m)), GPU $gpu ($free MiB free), $(julia --version), run directory $PWD"

# The rest of the log goes in the run directory, next to the run's output and checkpoints
# (#SBATCH --output can't use $RUN). slurm-<jobid>.out in the repository keeps the line above.
LOG=$PWD/slurm-$SLURM_JOB_ID.out
echo "log: $LOG"
exec > "$LOG" 2>&1
echo "job $SLURM_JOB_ID on $(hostname) ($(uname -m)), GPU $gpu ($free MiB free), $(julia --version), run directory $PWD"

# srun --unbuffered writes output to the log as it comes, so the --debug_nan diagnostics just before
# a crash are not lost in a buffer. Slurm sets CUDA_VISIBLE_DEVICES again for the job step, so
# env sets the allocated GPU once more inside the step.
cmd=(julia --project="$REPO" "$REPO/monsoon_convection.jl" --arch=gpu --wall_time="$WALL_TIME" "$@")
echo "command: ${cmd[*]}"
srun --unbuffered env CUDA_VISIBLE_DEVICES="$gpu" "${cmd[@]}"
