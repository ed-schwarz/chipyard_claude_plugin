#!/bin/bash
OUT=$1; NAME=$2; ELF=$3; shift 3
H=$(cd "$(dirname "$0")" && pwd)
D=$OUT/$NAME.done
[ -f "$D" ] && exit 0
exec 8> "$OUT/run/$NAME.lock"
flock -n 8 || exit 0
[ -f "$D" ] && exit 0
mapfile -t COMMON < "$OUT/run_args.txt"
RE=$(cat "$OUT/sim_regex.txt")
mine() {
  local c=0 f
  for f in "$OUT"/run/*.pid; do p=$(cat "$f" 2>/dev/null) && kill -0 "$p" 2>/dev/null && c=$((c + 1)); done
  echo $c
}
machine() {
  ps -eo stat=,args= | awk '$1 !~ /^[TZ]/ { n = split($2, a, "/"); print a[n] }' | grep -cE -- "$RE"
}
ok() {
  [ ! -e "$OUT/PAUSE" ] || return 1
  [ "$(mine)" -lt "$(cat "$OUT/cap.txt" 2>/dev/null || echo 1)" ] || return 1
  g=$(cat "$OUT/global_cap.txt" 2>/dev/null || echo 0)
  [ "$g" = 0 ] || [ "$(machine)" -lt "$g" ] || return 1
}
exec 7> "$OUT/cap.lock"
while true; do
  flock 7
  ok && break
  flock -u 7
  sleep 5
done
"$H/run_test.sh" "${COMMON[@]}" "$@" --elf "$ELF" --name "$NAME" --log "$OUT/logs/$NAME.log" --csv "$OUT/results.csv" > /dev/null 7>&- 8>&- &
rp=$!
echo "$rp" > "$OUT/run/$NAME.pid"
sleep 2
flock -u 7
exec 7>&-
wait $rp
rm -f "$OUT/run/$NAME.pid"
touch "$D"
exit 0
