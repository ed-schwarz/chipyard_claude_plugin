#!/bin/bash
set -u
usage() {
  cat <<'EOF'
usage: build.sh --chipyard DIR --config CONFIG [options]

  --chipyard DIR     Chipyard checkout (must contain sims/verilator)
  --config CONFIG    Chipyard CONFIG name (e.g. RocketConfig)
  --package PKG      CONFIG_PACKAGE, when the config is not in chipyard's package
  --threads N        VERILATOR_THREADS (default 1; use more only for a single sim)
  --jobs J           make -j (default 4)
  --fst              build the debug (waveform) simulator with FST output
  --vcd              build the debug (waveform) simulator with VCD output
  --heap SIZE        JAVA_HEAP_SIZE for the Scala/FIRRTL step (default 8G)
  --out DIR          copy the finished simulator into DIR (recommended: never run sweeps
                     straight out of the chipyard tree, a later build overwrites it)
  --model MODEL      harness module name in generated-src paths (default TestHarness)
  --name NAME        file name for the copy (default sim_<CONFIG>[-debug])
  --min-free-gb G    kill the build if MemAvailable drops below G GB (default 2)
  --dry-run          print what would run and exit
EOF
  exit 2
}
CY= CFG= PKG= VT=1 J=4 DBG=0 FST=0 HEAP=8G OUT= NAME= MODEL=TestHarness MINFREE=2 DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    --chipyard) CY=$2; shift ;;
    --config) CFG=$2; shift ;;
    --package) PKG=$2; shift ;;
    --threads) VT=$2; shift ;;
    --jobs) J=$2; shift ;;
    --fst) DBG=1; FST=1 ;;
    --vcd) DBG=1; FST=0 ;;
    --heap) HEAP=$2; shift ;;
    --out) OUT=$2; shift ;;
    --name) NAME=$2; shift ;;
    --model) MODEL=$2; shift ;;
    --min-free-gb) MINFREE=$2; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$CY" ] && [ -n "$CFG" ] || usage
CY=$(cd "$CY" && pwd) || exit 2
V=$CY/sims/verilator
[ -d "$V" ] || { echo "not a chipyard checkout: $V missing" >&2; exit 2; }

SUF=; TGT=; [ $DBG = 1 ] && { SUF=-debug; TGT=debug; }
MK=(make -C "$V" -j"$J" $TGT CONFIG="$CFG" VERILATOR_THREADS="$VT" JAVA_HEAP_SIZE="$HEAP")
[ -n "$PKG" ] && MK+=(CONFIG_PACKAGE="$PKG")
[ $DBG = 1 ] && MK+=(USE_FST=$FST)

stale_models() {
  for d in "$V"/generated-src/*."$MODEL"."$CFG"/*."$MODEL"."$CFG"$( [ $DBG = 1 ] && echo .debug ); do
    [ -d "$d" ] || continue
    f=$(ls "$d"/*__verFiles.dat 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    t=$(grep -oE -- '--threads [0-9]+' "$f" | head -1 | awk '{print $2}')
    [ -n "$t" ] && [ "$t" != "$VT" ] && echo "$d"
  done
}

if [ $DRY = 1 ]; then
  echo "would run: ${MK[*]}"
  for d in $(stale_models); do echo "would remove model dir built with other thread count: $d"; done
  exit 0
fi

for d in $(stale_models); do
  echo "removing model dir built with a different --threads: $d"
  rm -rf "$d"
done

if [ -f "$CY/env.sh" ]; then set +u; source "$CY/env.sh" >/dev/null 2>&1; set -u; fi
LOGDIR=${OUT:-$V}; mkdir -p "$LOGDIR"
LOG=$LOGDIR/build_${CFG}${SUF}.log
s=$(date +%s)
setsid "${MK[@]}" > "$LOG" 2>&1 < /dev/null &
mp=$!
oom=0
while kill -0 $mp 2>/dev/null; do
  a=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
  if [ "$a" -lt "$MINFREE" ]; then
    echo "MemAvailable ${a} GB < ${MINFREE} GB: killing build" | tee -a "$LOG" >&2
    kill -TERM -- -$mp 2>/dev/null; sleep 5; kill -KILL -- -$mp 2>/dev/null
    oom=1; break
  fi
  sleep 5
done
wait $mp; rc=$?
[ $oom = 1 ] && rc=137
el=$(( $(date +%s) - s ))
BIN=$(ls -t "$V"/simulator-*-"$CFG"$SUF 2>/dev/null | head -1)
if [ $rc -ne 0 ] || [ -z "$BIN" ]; then
  echo "BUILD FAILED rc=$rc ${el}s log=$LOG" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
GC=$(ls -d "$V"/generated-src/*."$MODEL"."$CFG"/gen-collateral 2>/dev/null | head -1)
if [ -n "$GC" ]; then
  newest_src=$(find "$CY/generators" -name '*.scala' -newer "$GC" -print -quit 2>/dev/null)
  [ -n "$newest_src" ] && echo "WARNING: $newest_src is newer than the generated Verilog; the simulator may not contain that edit" >&2
fi
if [ -n "$OUT" ]; then
  mkdir -p "$OUT"
  DST=$OUT/${NAME:-sim_${CFG}${SUF}}
  cp -p "$BIN" "$DST.tmp.$$" && mv -f "$DST.tmp.$$" "$DST"
  BIN=$DST
fi
echo "BUILD OK ${el}s sim=$BIN log=$LOG"
