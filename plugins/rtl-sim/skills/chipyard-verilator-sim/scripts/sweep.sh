#!/bin/bash
set -u
usage() {
  cat <<'EOF'
usage: sweep.sh --jobs FILE --out DIR [--parallel P] [--global-cap N [--sim-regex RE]] -- RUN_TEST_ARGS...

  --jobs FILE       one job per line: NAME ELF [extra run_test.sh args]; '#' lines are ignored
  --out DIR         results dir: logs/, results.csv, <NAME>.done markers, cap.txt, PAUSE
  --parallel P      max simulators this sweep runs at once; re-read from DIR/cap.txt on every
                    launch, so `echo N > DIR/cap.txt` changes it while the sweep runs (default 8)
  --global-cap N    also wait while N or more simulators run on the whole machine (anyone's),
                    counted by matching --sim-regex against the program name (default off)
  --sim-regex RE    extended regex for --global-cap (default '^(simulator-|sim_)')
  RUN_TEST_ARGS     passed to run_test.sh for every job, e.g. --sim S --cpu-limit 3600 --max-cycles 0

Re-running the same command resumes: jobs with a .done marker are skipped. To rerun a job,
delete its .done marker. Pause/resume with pause.sh. Summarize with summarize.sh.
EOF
  exit 2
}
H=$(cd "$(dirname "$0")" && pwd)
J= OUT= P=8 GCAP=0 RE='^(simulator-|sim_)'
while [ $# -gt 0 ]; do
  case $1 in
    --jobs) J=$2; shift ;;
    --out) OUT=$2; shift ;;
    --parallel) P=$2; shift ;;
    --global-cap) GCAP=$2; shift ;;
    --sim-regex) RE=$2; shift ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$J" ] && [ -n "$OUT" ] && [ -f "$J" ] || usage
mkdir -p "$OUT/logs" "$OUT/run"
OUT=$(cd "$OUT" && pwd)
exec 9> "$OUT/sweep.lock"
flock -n 9 || { echo "another sweep.sh is already running on $OUT" >&2; exit 1; }
echo "$P" > "$OUT/cap.txt"
echo "$GCAP" > "$OUT/global_cap.txt"
printf '%s\n' "$@" > "$OUT/run_args.txt"
echo "$RE" > "$OUT/sim_regex.txt"
n=$(grep -cvE '^[[:space:]]*(#|$)' "$J")
echo "$(date '+%F %T') START jobs=$n parallel=$P global_cap=$GCAP" >> "$OUT/sweep.log"
grep -vE '^[[:space:]]*(#|$)' "$J" | xargs -P 64 -L 1 "$H/sweep_worker.sh" "$OUT" 9>&-
echo "$(date '+%F %T') DONE" >> "$OUT/sweep.log"
"$H/summarize.sh" "$OUT"
