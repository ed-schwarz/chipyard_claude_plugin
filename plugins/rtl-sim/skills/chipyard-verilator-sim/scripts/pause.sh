#!/bin/bash
set -u
usage() {
  cat <<'EOF'
usage: pause.sh --out DIR [--resume] [--drain]

  default    stop new launches AND SIGSTOP every simulator this sweep started
  --drain    stop new launches only; running simulators finish normally
  --resume   SIGCONT the stopped simulators and allow launches again

A paused simulator keeps counting against a wall-clock --timeout (GNU timeout uses real
time). Sweeps that may be paused should use --cpu-limit, which does not advance while stopped.
EOF
  exit 2
}
OUT= MODE=pause
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUT=$2; shift ;;
    --resume) MODE=resume ;;
    --drain) MODE=drain ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$OUT" ] && [ -d "$OUT" ] || usage
desc() { local p=$1; echo "$p"; for c in $(cat /proc/"$p"/task/*/children 2>/dev/null); do desc "$c"; done; }
pids() {
  for f in "$OUT"/run/*.pid; do
    [ -f "$f" ] || continue
    r=$(cat "$f"); kill -0 "$r" 2>/dev/null || continue
    desc "$r"
  done | sort -u
}
case $MODE in
  drain)
    touch "$OUT/PAUSE"; echo "launches stopped; $(pids | wc -l) running processes left to finish" ;;
  pause)
    touch "$OUT/PAUSE"; P=$(pids)
    [ -n "$P" ] && kill -STOP $P
    echo "$P" > "$OUT/paused_pids.txt"
    echo "$(date '+%F %T') PAUSE $(echo $P | wc -w) processes" >> "$OUT/sweep.log"
    echo "paused $(echo $P | wc -w) processes" ;;
  resume)
    P=$(cat "$OUT/paused_pids.txt" 2>/dev/null; pids)
    [ -n "$P" ] && kill -CONT $(echo "$P" | sort -u) 2>/dev/null
    rm -f "$OUT/PAUSE" "$OUT/paused_pids.txt"
    echo "$(date '+%F %T') RESUME" >> "$OUT/sweep.log"
    echo "resumed" ;;
esac
