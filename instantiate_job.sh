#!/bin/bash
#SBATCH --job-name=instantiate
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=0:30:00
#SBATCH --output=slurm-instantiate-%j.out

# Download the pinned packages (Pkg.instantiate) into the depot of the node's architecture
# (helpers/arch_env.sh). It only downloads, no compiling, and needs internet on the node. Name a
# partition of the architecture to download for; run it once per architecture:
#   x86_64:   done on the login node, or  sbatch -p ceoas instantiate_job.sh
#   aarch64:  sbatch -p ceoas-arm instantiate_job.sh
# Follow it with  tail -f slurm-instantiate-<jobid>.out ; the log ends with "Instantiate done",
# or with the error. Then precompile (precompile_job.sh).

set -euo pipefail

source "$SLURM_SUBMIT_DIR/helpers/arch_env.sh"   # juliaup's Julia 1.13 and depot for this architecture

echo "instantiate job $SLURM_JOB_ID on $(hostname) ($(uname -m)), $(julia --version), JULIA_DEPOT_PATH=$JULIA_DEPOT_PATH"
JULIA_PKG_PRECOMPILE_AUTO=0 julia --project="$SLURM_SUBMIT_DIR" -e 'using Pkg; Pkg.instantiate()'
echo "Instantiate done"
