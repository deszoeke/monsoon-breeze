#!/bin/bash
#SBATCH --job-name=precompile
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G                 # precompiling needs ~6 GB; the login node allows less
#SBATCH --time=1:00:00
#SBATCH --output=slurm-precompile-%j.out

# Precompile MonsoonConvection on a compute node (it runs out of memory on the login node), into
# the depot of the node's architecture (helpers/arch_env.sh). No GPU is needed. Name a partition of
# the architecture to compile for; run it once per architecture after `git pull` or a package update:
#   x86_64:   sbatch -p ceoas precompile_job.sh
#   aarch64:  sbatch -p ceoas-arm precompile_job.sh
# The log ends with "Load check: ok", or with the error.

set -euo pipefail

source "$SLURM_SUBMIT_DIR/helpers/arch_env.sh"   # juliaup's Julia 1.13 and depot for this architecture

echo "precompile job $SLURM_JOB_ID on $(hostname) ($(uname -m)), $(julia --version), JULIA_CPU_TARGET=${JULIA_CPU_TARGET:-unset}"
julia --project="$SLURM_SUBMIT_DIR" "$SLURM_SUBMIT_DIR/setup_precompile.jl"
