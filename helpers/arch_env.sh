# Julia and Slurm environment for the CPU architecture of this machine. Source it, don't run it:
#     source helpers/arch_env.sh
# monsoon_job.sh sources it on the compute node; ~/.bashrc can source it for login shells.
#
# The home directory and /local/cluster are shared by x86_64 and aarch64 nodes, but programs and
# compiled Julia code are per architecture. Each architecture has its own juliaup, Julia depot and
# Slurm commands. Every variable is set (or unset) for each architecture, and the other
# architectures' directories are removed from PATH, because sbatch and srun copy the submitting
# shell's environment, which may come from a different architecture.
#
# To add an architecture: install juliaup there with its own JULIAUP_DEPOT_PATH, instantiate the
# project with its own JULIA_DEPOT_PATH, and add a case below and its directories to arch_dirs.

arch_dirs=(
    "$HOME/.juliaup/bin" /local/cluster/slurm/bin                                   # x86_64
    "$HOME/.juliaup-aarch64/bin" /local/cluster/aarch64/slurm/bin /local/cluster/aarch64/bin   # aarch64
)

case "$(uname -m)" in
    x86_64)
        juliaup_dir=$HOME/.juliaup
        export JULIAUP_DEPOT_PATH=$HOME/.julia
        export JULIA_DEPOT_PATH=$HOME/.julia:        # trailing ':' keeps Julia's bundled stdlib depots
        export JULIA_CPU_TARGET="haswell,-rdrnd"     # what the x86_64 depot was compiled for
        slurm_bin=/local/cluster/slurm/bin
        ;;
    aarch64)                                        # Grace Hopper GH200 nodes
        juliaup_dir=$HOME/.juliaup-aarch64
        export JULIAUP_DEPOT_PATH=$HOME/.juliaup-aarch64
        export JULIA_DEPOT_PATH=$HOME/.julia-aarch64:
        unset JULIA_CPU_TARGET                      # native
        slurm_bin=/local/cluster/aarch64/slurm/bin
        ;;
    *)
        echo "arch_env.sh: no Julia/Slurm setup for $(uname -m)" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

# Drop every architecture's directories from PATH, then put this one's first
path=":$PATH:"
for d in "${arch_dirs[@]}"; do
    while [[ $path == *":$d:"* ]]; do path=${path/:$d:/:}; done
done
path=${path#:}; path=${path%:}
export PATH="$juliaup_dir/bin:$slurm_bin:$path"
unalias julia 2>/dev/null || true
unset arch_dirs path d juliaup_dir slurm_bin
