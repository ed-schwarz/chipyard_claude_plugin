#!/bin/bash
set -u
usage() {
  cat <<'EOF'
usage: run_test.sh --sim SIM --elf ELF [options]

  --sim SIM            Verilator simulator binary (simulator-chipyard.harness-<CONFIG>[-debug])
  --elf ELF            RISC-V program
  --pk PK              run ELF under the proxy kernel PK (user-mode tests); PK is loaded with +loadmem
  --elf-args "ARGS"    arguments passed to the program
  --max-cycles N       +max-cycles bound in HARNESS cycles (default 100000000; 0 = none)
  --timeout S          wall-clock limit in seconds (default 3600)
  --cpu-limit S        CPU-time limit in seconds (SIGSTOP pauses and machine load do not eat into it)
  --dramsim-ini DIR    use DRAMSim2 with this ini dir (default: SimDRAM's magic memory model)
  --chipyard DIR       shorthand for --dramsim-ini DIR/generators/testchipip/src/main/resources/dramsim2_ini
  --quiet              omit +verbose (default passes it: it prints the "*** PASSED *** ... N simulation
                       cycles" line; omit it only when the design has huge printf output)
  --seed N             +verilator+seed+N (changes the RANDOMIZE_* register/memory init)
  --wave FILE          +vcdfile=FILE (debug simulator only; use .fst for an FST build)
  --plusargs "ARGS"    extra plusargs placed inside the +permissive block
  --name NAME          test name for the result line (default: basename of ELF)
  --log FILE           combined stdout+stderr log (default ./<NAME>.log)
  --csv FILE           append the result line to FILE

Prints one line: NAME,VERDICT,WALL_S,CYCLES,LOG
VERDICT is PASS, FAIL(<code>), CYCLE_TIMEOUT, WALL, CPU_LIMIT, ASSERT, or OTHER_<rc>.
EOF
  exit 2
}
SIM= ELF= PK= EARGS= MC=100000000 T=3600 CPU= DI= VB=1 SEED= WAVE= PA= NAME= LOG= CSV=
while [ $# -gt 0 ]; do
  case $1 in
    --sim) SIM=$2; shift ;;
    --elf) ELF=$2; shift ;;
    --pk) PK=$2; shift ;;
    --elf-args) EARGS=$2; shift ;;
    --max-cycles) MC=$2; shift ;;
    --timeout) T=$2; shift ;;
    --cpu-limit) CPU=$2; shift ;;
    --dramsim-ini) DI=$2; shift ;;
    --chipyard) DI=$2/generators/testchipip/src/main/resources/dramsim2_ini; shift ;;
    --verbose) VB=1 ;;
    --quiet) VB=0 ;;
    --seed) SEED=$2; shift ;;
    --wave) WAVE=$2; shift ;;
    --plusargs) PA=$2; shift ;;
    --name) NAME=$2; shift ;;
    --log) LOG=$2; shift ;;
    --csv) CSV=$2; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$SIM" ] && [ -n "$ELF" ] || usage
[ -x "$SIM" ] || { echo "simulator not executable: $SIM" >&2; exit 2; }
[ -f "$ELF" ] || { echo "ELF not found: $ELF" >&2; exit 2; }
[ -z "$PK" ] || [ -f "$PK" ] || { echo "pk not found: $PK" >&2; exit 2; }
[ -z "$DI" ] || [ -d "$DI" ] || { echo "dramsim ini dir not found: $DI" >&2; exit 2; }
NAME=${NAME:-$(basename "$ELF")}
LOG=${LOG:-./$NAME.log}
mkdir -p "$(dirname "$LOG")"

A=(+permissive)
[ -n "$DI" ] && A+=(+dramsim +dramsim_ini_dir="$DI")
[ -n "$SEED" ] && A+=(+verilator+seed+"$SEED")
[ $VB = 1 ] && A+=(+verbose)
[ -n "$WAVE" ] && A+=(+vcdfile="$WAVE")
[ "$MC" != 0 ] && A+=(+max-cycles="$MC")
[ -n "$PA" ] && A+=($PA)
if [ -n "$PK" ]; then
  A+=(+loadmem="$PK" +permissive-off "$PK" "$ELF")
else
  A+=(+loadmem="$ELF" +permissive-off "$ELF")
fi
[ -n "$EARGS" ] && A+=($EARGS)

s=$(date +%s)
(
  [ -n "$CPU" ] && ulimit -t "$CPU"
  exec timeout "$T" "$SIM" "${A[@]}"
) > "$LOG" 2>&1 < /dev/null
rc=$?
el=$(( $(date +%s) - s ))

cyc=$(grep -aoE 'after +[0-9]+ simulation cycles' "$LOG" | tail -1 | grep -oE '[0-9]+')
if [ $rc -eq 124 ]; then v=WALL
elif [ $rc -eq 152 ] || [ $rc -eq 137 -a -n "$CPU" ]; then v=CPU_LIMIT
elif grep -aqF '(timeout)' "$LOG"; then v=CYCLE_TIMEOUT
elif grep -aqE '\*\*\*[[:space:]]*FAILED' "$LOG"; then
  c=$(grep -aoE '(tohost|exit code) = *-?[0-9]+' "$LOG" | head -1 | sed 's/ //g')
  v="FAIL(${c:-?})"
elif grep -aqE 'Assertion failed|%Error|Aborted|Segmentation fault' "$LOG"; then v=ASSERT
elif [ $rc -eq 0 ]; then v=PASS
else v=OTHER_$rc
fi
line="$NAME,$v,$el,${cyc:-NA},$LOG"
echo "$line"
[ -n "$CSV" ] && echo "$line" >> "$CSV"
[ "$v" = PASS ]
