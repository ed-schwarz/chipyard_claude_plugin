#!/usr/bin/env python3
import argparse
import os
import re
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def fstq_bin(arg):
    p = arg or os.environ.get("FSTQ") or os.path.join(HERE, "fstq")
    if not os.access(p, os.X_OK):
        sys.exit(f"fstq not found at {p}; run build_fstq.sh first or pass --fstq")
    return p


def run(fq, *args):
    r = subprocess.run([fq, *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"fstq {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def list_vars(fq, fst, parts):
    out = []
    for line in run(fq, fst, "list", *parts).splitlines():
        f = line.split(" ", 2)
        if len(f) == 3:
            out.append((f[0], int(f[1]), re.sub(r" \[[0-9:]+\]$", "", f[2].replace(" (alias)", ""))))
    return out


def resolve(fq, fst, spec, allow_many):
    parts = [p for p in spec.split(",") if p]
    vs = list_vars(fq, fst, parts)
    exact = [v for v in vs if v[2].endswith("." + parts[-1]) or v[2] == parts[-1]]
    if exact:
        vs = exact
    if not vs:
        sys.exit(f"no signal matches {spec!r}")
    if len(vs) > 1 and not allow_many:
        shown = "\n  ".join(v[2] for v in sorted(vs, key=lambda v: len(v[2]))[:15])
        sys.exit(f"{spec!r} matches {len(vs)} signals; add more comma-separated substrings or use --all-matches:\n  {shown}")
    return vs


def fmt(v, radix):
    if any(c not in "01" for c in v):
        return v
    n = int(v, 2)
    if len(v) == 1:
        return str(n)
    return str(n) if radix == "dec" else hex(n)


def main():
    ap = argparse.ArgumentParser(description="Per-cycle signal table from an FST, sampled at a clock edge")
    ap.add_argument("fst")
    ap.add_argument("--fstq")
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list", help="list signals whose full path contains ALL substrings")
    ls.add_argument("substr", nargs="+")
    sub.add_parser("info", help="start/end time, timescale, variable count")
    tb = sub.add_parser("table", help="sample signals at each clock edge")
    tb.add_argument("--clock", required=True, help="clock signal (comma-separated substrings)")
    tb.add_argument("--sig", action="append", required=True, help="signal spec; repeatable")
    tb.add_argument("--edge", choices=["rise", "fall"], default="rise")
    tb.add_argument("--t0", type=int, default=0, help="start time (FST time units)")
    tb.add_argument("--t1", type=int, default=None, help="end time (FST time units)")
    tb.add_argument("--changes", action="store_true", help="print only cycles where a sampled value changed")
    tb.add_argument("--when", help="print only cycles where this signal (one of --sig, by column name) is non-zero")
    tb.add_argument("--count", action="store_true", help="for each 1-bit signal: cycles high and longest run of consecutive high cycles")
    tb.add_argument("--radix", choices=["hex", "dec"], default="hex")
    tb.add_argument("--all-matches", action="store_true")
    a = ap.parse_args()
    fq = fstq_bin(a.fstq)

    if a.cmd == "info":
        print(run(fq, a.fst, "info"), end="")
        return
    if a.cmd == "list":
        for h, w, p in list_vars(fq, a.fst, a.substr):
            print(f"{p}  [{w}]")
        return

    clk = resolve(fq, a.fst, a.clock, False)[0]
    cols = []
    for s in a.sig:
        for v in resolve(fq, a.fst, s, a.all_matches):
            cols.append(v)
    names = []
    for h, w, p in cols:
        short = p.rsplit(".", 1)[-1]
        names.append(short if [c[2].rsplit(".", 1)[-1] for c in cols].count(short) == 1 else p.rsplit(".", 2)[-2] + "." + short)
    info = run(fq, a.fst, "info").split()
    t1 = a.t1 if a.t1 is not None else int(info[3])
    handles = sorted({clk[0]} | {c[0] for c in cols}, key=int)
    proc = subprocess.Popen([fq, a.fst, "dump", str(a.t0), str(t1), *handles], stdout=subprocess.PIPE, text=True)
    cur = {}
    want = "1" if a.edge == "rise" else "0"
    rows = []
    pending = {}
    last_t = None

    def flush(t):
        clk_new = pending.get(clk[0])
        if clk_new is not None and clk_new == want and cur.get(clk[0]) != want:
            rows.append((t, [cur.get(c[0], "?") for c in cols]))
        cur.update(pending)
        pending.clear()

    for line in proc.stdout:
        f = line.split()
        if len(f) != 3:
            continue
        t = int(f[0])
        if last_t is not None and t != last_t:
            flush(last_t)
        last_t = t
        pending[f[1]] = f[2]
    if last_t is not None:
        flush(last_t)
    proc.wait()

    if a.count:
        print(f"{len(rows)} {a.edge} edges sampled")
        for i, (h, w, p) in enumerate(cols):
            if w != 1:
                continue
            hi = run_len = best = 0
            for _, vals in rows:
                if vals[i] == "1":
                    hi += 1
                    run_len += 1
                    best = max(best, run_len)
                else:
                    run_len = 0
            print(f"{names[i]}: high {hi} cycles, longest run {best}")
        return

    wi = names.index(a.when) if a.when else None
    print("time\tedge\t" + "\t".join(names))
    prev = None
    for n, (t, vals) in enumerate(rows):
        if wi is not None and (vals[wi] in ("?",) or all(c == "0" for c in vals[wi])):
            continue
        if a.changes and vals == prev:
            continue
        prev = vals
        print(f"{t}\t{n}\t" + "\t".join(fmt(v, a.radix) for v in vals))


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    main()
