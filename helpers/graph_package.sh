#!/bin/bash
# Build graphify code graphs of the package sources this project uses, for code analysis:
#     helpers/graph_package.sh                     # Breeze and Oceananigans
#     helpers/graph_package.sh Breeze              # just one
#     graphify query "<question>" --graph graphify-breeze/graphify-out/graph.json
# graphify skips symlinks, so this copies each package's src into graphify-<name>/ (untracked).
# A package whose copy already matches its version in the Manifest is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
packages=("$@")
(( ${#packages[@]} )) || packages=(Breeze Oceananigans)
for pkg in "${packages[@]}"; do
    read -r dir version < <(julia --project=. -e "using $pkg; println(pkgdir($pkg), ' ', pkgversion($pkg))")
    out=graphify-$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
    if [[ -f $out/VERSION && $(cat "$out/VERSION") == "$version" ]]; then
        echo "$pkg $version graph is up to date: $out/graphify-out/graph.json"
        continue
    fi
    rm -rf "$out"
    mkdir -p "$out"
    cp -R "$dir/src" "$out/src"
    graphify update "$out" 2>&1 | grep -v "skill at" | grep -v "^Tip:" || true
    echo "$version" > "$out/VERSION"
    echo "$pkg $version graph: $out/graphify-out/graph.json"
done
