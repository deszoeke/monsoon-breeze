#!/bin/bash
#SBATCH --job-name=monsoon
#SBATCH --cpus-per-task=1         # the run is GPU-bound
#SBATCH --mem=32G                 # Julia, compilation, checkpoint writing
#SBATCH --time=12:00:00           # short diagnostic runs; for long ones pass e.g. sbatch --time=48:00:00
#SBATCH --output=slurm-%j.out

# Breeze monsoon-convection run on one GPU. The run directory holds its own copy of
# monsoon_convection.jl, whose settings block is the whole run configuration; this script takes
# only that directory. The hardware goes on the sbatch line; the script sets up Julia and Slurm
# for whatever architecture the job lands on (helpers/arch_env.sh).
#
#   mkdir -p run/exp && cp monsoon_convection.jl run/exp/     # then edit its settings
#
# Partitions (account ceoas):
#   ceoas-gpu          x86_64 + A100 80 GB          --gres=gpu:a100:1          (aerosmith)
#   ceoas-arm          aarch64 Grace Hopper, 96 GB  --gres=gpu:gh200_480gb:1   (rime, youmu)
#   ceoas-arm-lowprio  the GH200 nodes, preemptible: a preempted job is requeued and reruns the
#                      run directory's copy as it is (set restart = true there first)
#   ceoas              x86_64 CPU only (precompile_job.sh)
#
# Submit from the repository directory:
#   sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/one-moment
#   sbatch -p ceoas-gpu --gres=gpu:a100:1 monsoon_job.sh run/one-moment
#   sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 --time=48:00:00 monsoon_job.sh run/one-moment
#   jid=$(sbatch --parsable -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp)
#   sbatch --dependency=afterok:$jid -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp
#       (a chained continuation runs the copy as it is then: set restart = true before it starts)
# Interactive shell on a GPU node:
#   srun -p ceoas-arm --gres=gpu:gh200_480gb:1 --mem=32G --time=1:00:00 --pty bash
#   srun -p ceoas-gpu --gres=gpu:a100:1 --mem=32G --time=1:00:00 --pty bash
#
# The run stops and checkpoints 10 min before the job's time limit (monsoon_convection.jl reads
# SLURM_JOB_END_TIME). The log is <run directory>/slurm-<jobid>.out; slurm-<jobid>.out in the
# repository only says where it is.

set -euo pipefail

REPO=$SLURM_SUBMIT_DIR
usage="usage: sbatch -p <partition> --gres=<gpu> monsoon_job.sh <run directory>
  (the directory must hold its copy of the driver: mkdir -p run/exp && cp monsoon_convection.jl run/exp/)"
(( $# == 1 )) || { echo "$usage" >&2; exit 1; }
[[ -f $1/monsoon_convection.jl ]] || { echo "no $1/monsoon_convection.jl" >&2; echo "$usage" >&2; exit 1; }
cd "$1"
source "$REPO/helpers/arch_env.sh"   # juliaup's Julia 1.13 and Slurm's srun for this architecture

# Slurm gives the job one GPU of its own, but processes started outside Slurm can still be on it.
# Stop at once if they leave too little memory for the run (estimated 10–20 GB; check nvidia-smi on a running job).
: "${CUDA_VISIBLE_DEVICES:?no GPU allocated to this job}"
gpu=$CUDA_VISIBLE_DEVICES
free=$(nvidia-smi -i "$gpu" --query-gpu=memory.free --format=csv,noheader,nounits)
(( free >= 40000 )) || { echo "GPU $gpu has only $free MiB free" >&2; exit 1; }

header="job $SLURM_JOB_ID on $(hostname) ($(uname -m)), GPU $gpu ($free MiB free), $(julia --version), run directory $PWD"
echo "$header"

# The rest of the log goes in the run directory, next to the run's output and checkpoints
# (#SBATCH --output can't name it). slurm-<jobid>.out in the repository keeps the lines above.
LOG=$PWD/slurm-$SLURM_JOB_ID.out
echo "log: $LOG"
exec > "$LOG" 2>&1
echo "$header"
echo "settings:"
sed -n '/^##### Settings/,/^##### Setup/p' monsoon_convection.jl | grep -E '^[a-z_]+ += ' | sed 's/ *#.*//; s/^/  /'

# srun --unbuffered writes output to the log as it comes, so the debug_nan diagnostics just before
# a crash are not lost in a buffer. Slurm sets CUDA_VISIBLE_DEVICES again for the job step, so
# env sets the allocated GPU once more inside the step. --cpu-bind=none: on aerosmith the step's
# default CPU binding falls outside the allocation ("Unable to satisfy cpu bind request").
srun --unbuffered --cpu-bind=none env CUDA_VISIBLE_DEVICES="$gpu" julia --project="$REPO" monsoon_convection.jl
