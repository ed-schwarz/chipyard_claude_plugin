#!/bin/bash
set -u
[ $# -ge 1 ] || { echo "usage: summarize.sh OUT_DIR [--list]" >&2; exit 2; }
OUT=$1; LIST=${2:-}
R=$OUT/results.csv
[ -f "$R" ] || { echo "no results yet in $R"; exit 0; }
LAT=$(tac "$R" | awk -F, '!seen[$1]++')
echo "tests with a result: $(echo "$LAT" | grep -c .)"
echo "$LAT" | awk -F, '{ v = $2; sub(/\(.*/, "", v); c[v]++ } END { for (k in c) printf "  %-14s %d\n", k, c[k] }' | sort
if [ "$LIST" = --list ]; then
  echo "non-PASS (latest row per test):"
  echo "$LAT" | awk -F, '$2 != "PASS" { printf "  %s %s %ss %s\n", $1, $2, $3, $5 }' | sort
fi
run=$(ls "$OUT"/run/*.pid 2>/dev/null | wc -l)
[ -e "$OUT/PAUSE" ] && echo "state: PAUSED ($run in flight)" || echo "state: $run in flight"
