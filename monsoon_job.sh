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
# check the partition's GPU request syntax and limits, and on a GPU node run
#   julia --project setup_precompile.jl && julia --project check_gpu.jl --smoke_test

#SBATCH --job-name=monsoon
#SBATCH --partition=ceoas-gpu
#SBATCH --gres=gpu:a100:2          # A100 80 GB (ceoas-gpu also has GTX 1080 Ti nodes: 11 GB, too small).
                                   # TEMPORARY: 2 GPUs, the run uses one (see USE_GPU below), because
                                   # Slurm keeps assigning aerosmith GPU 2, which a job that did not
                                   # request a GPU is using. Back to gpu:a100:1 once that is resolved.
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G                  # host memory; output is staged on the host before writing
#SBATCH --time=48:00:00            # within the partition limit (sinfo -p ceoas-gpu -o %l)
#SBATCH --output=slurm-%j.out

set -euo pipefail

# Repository location (override at submission: REPO=/other/path sbatch monsoon_job.sh)
REPO=${REPO:-/ceoas/deszoeks/projects/monsoon-breeze}

# Run directory for output and checkpoints (one per experiment)
RUN=${RUN:-$REPO/run}

# Real-time limit for the model: stop and checkpoint about 1 h before the Slurm --time limit,
# leaving room for startup (CUDA kernel compilation) and the final checkpoint write.
WALL_TIME=${WALL_TIME:-47h}

# Julia executable: must be the version the environment was set up with (Manifest.toml).
# Batch jobs can find a different `julia` on PATH (e.g. a system 1.10); override with e.g.
#   JULIA=$HOME/.juliaup/bin/julia sbatch monsoon_job.sh
JULIA=${JULIA:-julia}

# Which of the allocated GPUs to run on:
#   USE_GPU=idle (default)  the first allocated GPU with < 1 GiB in use
#   USE_GPU=3               that GPU (must be one Slurm allocated to this job), e.g.
#                           USE_GPU=3 sbatch monsoon_job.sh
# The job stops before starting the model if the chosen GPU is busy or not allocated.
# (On this cluster CUDA_VISIBLE_DEVICES holds the node's physical GPU indices, as nvidia-smi.)
USE_GPU=${USE_GPU:-idle}

# Julia environment: use the same values as when precompiling (see README), e.g.
# export JULIA_DEPOT_PATH=/path/to/shared/julia_depot
# export JULIA_CPU_TARGET="generic;skylake-avx512,clone_all;znver3,clone_all"

mkdir -p "$RUN"
cd "$RUN"

echo "job $SLURM_JOB_ID on $(hostname) at $(date)"
echo "run directory: $PWD"
echo "repository:    $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
echo "arguments:     --arch=gpu --wall_time=$WALL_TIME $*"
nvidia-smi --query-gpu=index,name,memory.used,memory.total,driver_version --format=csv

# Choose one of the allocated GPUs (see USE_GPU above).
allocated=${CUDA_VISIBLE_DEVICES:-}
echo "allocated GPUs: ${allocated:-none}"
[ -n "$allocated" ] || { echo "ERROR: no GPU allocated to this job (CUDA_VISIBLE_DEVICES unset)" >&2; exit 1; }
used_mib() { nvidia-smi -i "$1" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' '; }
if [ "$USE_GPU" = "idle" ]; then
    gpu=""
    for g in ${allocated//,/ }; do
        if [ "$(used_mib "$g")" -lt 1024 ]; then gpu=$g; break; fi
    done
    [ -n "$gpu" ] || { echo "ERROR: all allocated GPUs ($allocated) are busy; nothing was run" >&2; exit 1; }
else
    case ",$allocated," in
        *",$USE_GPU,"*) gpu=$USE_GPU ;;
        *) echo "ERROR: USE_GPU=$USE_GPU is not among the allocated GPUs ($allocated)" >&2; exit 1 ;;
    esac
    [ "$(used_mib "$gpu")" -lt 1024 ] || { echo "ERROR: GPU $gpu is busy ($(used_mib "$gpu") MiB in use); nothing was run" >&2; exit 1; }
fi
export CUDA_VISIBLE_DEVICES=$gpu
echo "running on GPU: $gpu ($(used_mib "$gpu") MiB in use before start)"

# Stop early if this Julia is not the version in Manifest.toml (wrong julia on PATH).
want=$(sed -n 's/^julia_version = "\([0-9]*\.[0-9]*\).*/\1/p' "$REPO/Manifest.toml")
have=$("$JULIA" -e 'print(VERSION.major, ".", VERSION.minor)')
echo "julia:         $(command -v "$JULIA") version $have (Manifest.toml: $want)"
if [ "$have" != "$want" ]; then
    echo "ERROR: Julia $have does not match Manifest.toml ($want). Set JULIA=/path/to/julia-$want, e.g." >&2
    echo "       JULIA=\$HOME/.juliaup/bin/julia sbatch monsoon_job.sh" >&2
    exit 1
fi

# A single process: run Julia directly. (srun is not needed, and inside a batch job submitted
# from an interactive allocation it inherits that allocation's CPU binding and fails.)
"$JULIA" --project="$REPO" "$REPO/monsoon_convection.jl" --arch=gpu --wall_time="$WALL_TIME" "$@"

echo "finished at $(date)"
