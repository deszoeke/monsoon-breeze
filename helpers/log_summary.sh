#!/bin/bash
# Reduce a monsoon_convection log to what matters for diagnosis. Run where the log is:
#
#   helpers/log_summary.sh run/one-moment/<log file>
#
# Prints: the last progress line; any NaN/error lines; and, from the debug_nan "bounds" lines,
# for each field the number of violations, the worst value, and where the extremes sit
# (by height and by T above/below 273.15 K).
log=${1:?usage: helpers/log_summary.sh <log file>}

echo "== last progress line"
grep -E '^\[ Info: Iter:' "$log" | tail -1 | cut -c1-200

echo "== NaN / errors (first 5)"
grep -nE 'NaN|Inf found|ERROR|stopping at first' "$log" | head -5 | cut -c1-200

echo "== bounds violations (lines from debug_nan = true)"
awk '
/^bounds / {
    f = $2; n[f]++
    match($0, /range \[[^,]+/); lo = substr($0, RSTART + 7, RLENGTH - 7) + 0
    if (!(f in worst) || lo < worst[f]) { worst[f] = lo; worstline[f] = $0 }
    match($0, /z = [0-9]+/); z = substr($0, RSTART + 4, RLENGTH - 4) + 0
    match($0, /T = [0-9.]+/); T = substr($0, RSTART + 4, RLENGTH - 4) + 0
    zb = int(z / 1000); zc[f, zb]++; if (zb > zmax) zmax = zb
    if (T < 273.15) cold[f]++
    if (first == "") first = $4; last = $4
}
END {
    if (first == "") { print "  none"; exit }
    printf "  iterations %s–%s\n", first, last
    for (f in n) {
        printf "  %-5s %d violations; %d with T < 273.15 K\n", f, n[f], cold[f]
        printf "        worst: %s\n", substr(worstline[f], index(worstline[f], "iter"))
        printf "        extremes by height (km: count):"
        for (b = 0; b <= zmax; b++) if ((f, b) in zc) printf " %d–%d: %d", b, b + 1, zc[f, b]
        printf "\n"
    }
}' "$log"
