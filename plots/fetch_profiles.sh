#!/bin/bash
# Copy the small _profiles.nc files (~300 KB) of runs from the cluster to the local run/<name>/,
# for plotting on the Mac. Read-only on the cluster, so safe while runs are writing.
#     plots/fetch_profiles.sh                      # the P3 tree
#     plots/fetch_profiles.sh ekamsat-ctl0 ...     # named runs
# Output files are git-ignored (*.nc).

host=hpc.ceoas.oregonstate.edu
remote=/ceoas/deszoeks/projects/monsoon-breeze/run
runs=("$@")
[ ${#runs[@]} -eq 0 ] && runs=( ekamsat-p3-ctl0 ekamsat-p3-ctl2 ekamsat-p3-moisten1000-850
                                ekamsat-p3-moisten850-650 ekamsat-p3-moisten650-440 
			        one-moment/ekamsat-ctl0 one-moment/ekamsat-ctl2 
				one-moment/ekamsat-moisten1000-850 one-moment/ekamsat-moisten850-650
				one-moment/ekamsat-moisten650-440 )

local_run="$(cd "$(dirname "$0")/.." && pwd)/run"
for r in "${runs[@]}"; do
    mkdir -p "$local_run/$r"
    rsync -rt --include='*_profiles.nc' --exclude='*' "$host:$remote/$r/" "$local_run/$r/" \
        && echo "$r" || echo "$r: failed"
done
