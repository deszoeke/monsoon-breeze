#!/bin/bash
#SBATCH --job-name=precompile
#SBATCH --partition=ceoas
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G                 # precompiling needs ~6 GB; the login node allows less
#SBATCH --time=1:00:00
#SBATCH --output=slurm-precompile-%j.out

# Precompile MonsoonConvection on a compute node (it runs out of memory on the login node).
# No GPU is needed: with the portable JULIA_CPU_TARGET from ~/.bashrc (inherited by the job),
# the compiled cache works on every node type.
# Submit from the repository directory, after `git pull` or a package update:
#   sbatch precompile_job.sh
# The log ends with "Load check: ok", or with the error.

set -euo pipefail

export PATH="$HOME/.juliaup/bin:$PATH"     # juliaup's Julia 1.13, not the system julia

echo "precompile job $SLURM_JOB_ID on $(hostname), $(julia --version), JULIA_CPU_TARGET=${JULIA_CPU_TARGET:-unset}"
julia --project="$SLURM_SUBMIT_DIR" "$SLURM_SUBMIT_DIR/setup_precompile.jl"
