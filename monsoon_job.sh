#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --cpus-per-task=2         # the run is GPU-bound
#SBATCH --mem=32G                 # Julia, compilation, checkpoint writing
#SBATCH --time=02:00:00           # short diagnostic runs; for long ones pass e.g. sbatch --time=48:00:00
#SBATCH --output=slurm-%j.out

# Breeze monsoon-convection run on one A100 GPU (partition ceoas-gpu). For a Grace Hopper GH200
# (partition ceoas-arm), submit monsoon_job_arm.sh the same way instead.
#
# Submit from the repository directory; arguments go to monsoon_convection.jl:
#   sbatch monsoon_job.sh                      # first job
#   sbatch monsoon_job.sh --restart            # continuation, until the stop time is reached
#   RUN=run/sst302 sbatch monsoon_job.sh       # another experiment in its own run directory
# Output, checkpoints and the log (slurm-<jobid>.out) go to $RUN (default run/). The
# slurm-<jobid>.out in the repository only says where the run directory is.

set -euo pipefail

# juliaup's Julia 1.13, not the system julia. x86 and ARM each have their own juliaup and depot (the
# home directory is shared, and compiled code is per architecture). Set or unset everything in both
# branches: sbatch copies the submitting shell's environment, which may be from the other architecture.
if [ "$(uname -m)" = aarch64 ]; then        # Grace Hopper (monsoon_job_arm.sh)
    export JULIAUP_DEPOT_PATH=$HOME/.juliaup-aarch64 JULIA_DEPOT_PATH=$HOME/.julia-aarch64
    unset JULIA_CPU_TARGET
    export PATH="$HOME/.juliaup-aarch64/bin:$PATH"
else
    unset JULIAUP_DEPOT_PATH JULIA_DEPOT_PATH
    export JULIA_CPU_TARGET="haswell,-rdrnd"   # what the x86 depot was compiled with (~/.bashrc)
    export PATH="$HOME/.juliaup/bin:$PATH"
fi
REPO=$SLURM_SUBMIT_DIR
RUN=${RUN:-run}
# Stop and checkpoint 10 min before the job's time limit (whatever --time it was given), unless
# WALL_TIME is set. squeue prints the limit as [days-][hours:]minutes:seconds.
limit=$(squeue -h -j "$SLURM_JOB_ID" -o %l)
days=0; [[ $limit == *-* ]] && { days=${limit%%-*}; limit=${limit#*-}; }
IFS=: read -r -a hms <<< "$limit"
(( ${#hms[@]} == 3 )) || hms=(0 "${hms[@]}")
limit_min=$(( 10#$days * 1440 + 10#${hms[0]} * 60 + 10#${hms[1]} ))
WALL_TIME=${WALL_TIME:-$(( limit_min - 10 ))min}

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
