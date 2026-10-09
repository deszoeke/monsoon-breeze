#!/bin/bash
# Build graphify code graphs of the package sources this project uses, for code analysis:
#     helpers/graph_package.sh                     # Breeze and Oceananigans
#     helpers/graph_package.sh Breeze              # just one
#     graphify query "<question>" --graph graphify-breeze/graphify-out/graph.json
# graphify skips symlinks, so this copies each package's src into graphify-<name>/ (untracked).
# A graph is rebuilt only when the package's source differs from the copy (after a Pkg update,
# a pull that changes the Manifest, a fresh clone, or a dev'd package edit); otherwise it is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

packages=("$@")
(( ${#packages[@]} )) || packages=(Breeze Oceananigans)

# hash of every file under a src directory (paths and contents)
src_hash() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -d' ' -f1); }

# one Julia call for all package directories
dirs=$(julia --project=. -e "for p in ARGS; println(pkgdir(Base.require(Main, Symbol(p)))); end" "${packages[@]}")

i=0
while read -r dir; do
    pkg=${packages[$i]}; i=$((i + 1))
    out=graphify-$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
    hash=$(src_hash "$dir/src")
    if [[ -f $out/SOURCE_HASH && $(cat "$out/SOURCE_HASH") == "$hash" && -f $out/graphify-out/graph.json ]]; then
        echo "$pkg graph is current: $out/graphify-out/graph.json"
        continue
    fi
    rm -rf "$out"
    mkdir -p "$out"
    cp -R "$dir/src" "$out/src"
    graphify update "$out" 2>&1 | grep -v "skill at" | grep -v "^Tip:" || true
    echo "$hash" > "$out/SOURCE_HASH"
    echo "$dir" > "$out/SOURCE_DIR"
    echo "$pkg graph rebuilt from $dir: $out/graphify-out/graph.json"
done <<< "$dirs"
