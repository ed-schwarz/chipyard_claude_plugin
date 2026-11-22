#!/bin/bash
set -eu
usage() { echo "usage: build_fstq.sh [--verilator-root DIR] [--out FILE]   (default out: fstq next to this script)" >&2; exit 2; }
H=$(cd "$(dirname "$0")" && pwd)
VR= OUT=$H/fstq
while [ $# -gt 0 ]; do
  case $1 in
    --verilator-root) VR=$2; shift ;;
    --out) OUT=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "$VR" ] || VR=$(verilator --getenv VERILATOR_ROOT 2>/dev/null || true)
G=$VR/include/gtkwave
[ -f "$G/fstapi.c" ] || { echo "fstapi.c not found under $G; pass --verilator-root" >&2; exit 1; }
T=$(mktemp -d)
cc -O2 -DFST_CONFIG_INCLUDE="\"fst_config.h\"" -I"$G" -c "$G/fstapi.c" -o "$T/fstapi.o"
cc -O2 -DFST_CONFIG_INCLUDE="\"fst_config.h\"" -I"$G" -c "$G/lz4.c" -o "$T/lz4.o"
cc -O2 -DFST_CONFIG_INCLUDE="\"fst_config.h\"" -I"$G" -c "$G/fastlz.c" -o "$T/fastlz.o"
cc -O2 -DFST_CONFIG_INCLUDE="\"fst_config.h\"" -I"$G" "$H/fstq.c" "$T"/*.o -lz -lpthread -o "$OUT"
rm -rf "$T"
echo "built $OUT"
