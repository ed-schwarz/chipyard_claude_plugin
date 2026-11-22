#!/usr/bin/env python3
import argparse
import re
import signal
import sys

HEXPAIR = re.compile(r"0x([0-9a-fA-F]+) \(0x([0-9a-fA-F]+)\)")
PRIV = re.compile(r"(?:^|:)\s*([0-3]) 0x[0-9a-fA-F]+ \(0x")
WB = re.compile(r"\b([xf])\s*(\d+) 0x([0-9a-fA-F]+)")
ROCKET = re.compile(r"C\d+: *\d+ \[(\d)\] pc=\[([0-9a-fA-F]+)\] W\[r\s*(\d+)=([0-9a-fA-F]+)\]\[(\d)\].*?inst=\[([0-9a-fA-F]+)\]")


def parse(path, core, values):
    recs = []
    has_priv = False
    with open(path, "r", errors="replace") as f:
        lines = f.readlines()
    for ln in lines:
        if PRIV.search(ln):
            has_priv = True
            break
    for no, ln in enumerate(lines, 1):
        if core is not None and "core" in ln and not re.search(rf"core\s+{core}:", ln):
            continue
        m = ROCKET.search(ln)
        if m:
            valid, pc, rd, val, wen, inst = m.groups()
            if valid != "1":
                continue
            wb = (("x", int(rd), int(val, 16)),) if wen == "1" and int(rd) != 0 else ()
            recs.append((int(pc, 16), int(inst, 16), wb if values else (), no, ln.rstrip()))
            continue
        m = HEXPAIR.search(ln)
        if not m:
            continue
        if has_priv and not PRIV.search(ln):
            continue
        pc, inst = int(m.group(1), 16), int(m.group(2), 16)
        wb = ()
        if values:
            tail = ln[m.end():]
            wb = tuple((k, int(r), int(v, 16)) for k, r, v in WB.findall(tail) if not (k == "x" and int(r) == 0))
        recs.append((pc, inst, wb, no, ln.rstrip()))
    return recs


def first_common(a, b, start_pc):
    if start_pc is not None:
        ia = next((i for i, r in enumerate(a) if r[0] == start_pc), None)
        ib = next((i for i, r in enumerate(b) if r[0] == start_pc), None)
        return ia, ib
    pos = {}
    for i, r in enumerate(b):
        pos.setdefault((r[0], r[1]), i)
    for i, r in enumerate(a):
        j = pos.get((r[0], r[1]))
        if j is not None:
            return i, j
    return None, None


def resync(a, b, i, j, window, need=8):
    def key(r):
        return (r[0], r[1])
    pos = {}
    for dj in range(min(window, len(b) - j)):
        pos.setdefault(key(b[j + dj]), []).append(dj)
    best = None
    for di in range(min(window, len(a) - i)):
        for dj in pos.get(key(a[i + di]), ()):
            if best is not None and di + dj >= best[0] + best[1]:
                break
            n = min(need, len(a) - i - di, len(b) - j - dj)
            if all(key(a[i + di + k]) == key(b[j + dj + k]) for k in range(n)):
                best = (di, dj)
                break
        if best is not None and di >= best[0] + best[1]:
            break
    return best


def parse_pcs(spec):
    out = []
    for part in spec.split(","):
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.append((int(lo, 0), int(hi, 0)))
        else:
            v = int(part, 0)
            out.append((v, v))
    return out


def show(tag, recs, k, ctx):
    for x in range(max(0, k - ctx), min(len(recs), k + 2)):
        mark = ">>" if x == k else "  "
        print(f"  {tag}{mark} line {recs[x][3]}: {recs[x][4][:160]}")


def main():
    ap = argparse.ArgumentParser(description="Find where two commit/instruction logs diverge (e.g. RTL commit log vs spike)")
    ap.add_argument("a", help="first log (e.g. RTL commit log)")
    ap.add_argument("b", help="second log (e.g. spike -l --log-commits stderr)")
    ap.add_argument("--start-pc", type=lambda s: int(s, 0), help="align both logs at the first commit of this PC")
    ap.add_argument("--no-values", action="store_true", help="compare PC and instruction only")
    ap.add_argument("--core", type=int, help="only lines of this hart ('core N:') in spike logs")
    ap.add_argument("--context", type=int, default=5)
    ap.add_argument("--max-diffs", type=int, default=1, help="after a divergence, resync and keep going up to this many")
    ap.add_argument("--window", type=int, default=20000, help="resync search window (records)")
    ap.add_argument("--resync-match", type=int, default=8, help="consecutive matching records required to accept a resync point")
    ap.add_argument("--ignore-pc", default="", help="drop records at these PCs from both logs before comparing, e.g. 0x8000384e,0x80003850 or 0x1000-0x10ff (busy-wait loops, interrupt handlers)")
    a = ap.parse_args()
    vals = not a.no_values
    A = parse(a.a, a.core, vals)
    B = parse(a.b, a.core, vals)
    ign = parse_pcs(a.ignore_pc)
    if ign:
        keep = lambda r: not any(lo <= r[0] <= hi for lo, hi in ign)
        A = [r for r in A if keep(r)]
        B = [r for r in B if keep(r)]
    print(f"{a.a}: {len(A)} records, {a.b}: {len(B)} records")
    if not A or not B:
        sys.exit("a log has no recognizable commit lines")
    i, j = first_common(A, B, a.start_pc)
    if i is None:
        sys.exit("no common starting point; pass --start-pc")
    print(f"aligned at A line {A[i][3]} / B line {B[j][3]} (pc {A[i][0]:#x})")
    diffs = 0
    compared = 0
    while i < len(A) and j < len(B):
        ra, rb = A[i], B[j]
        bad = None
        if (ra[0], ra[1]) != (rb[0], rb[1]):
            bad = f"pc/inst differ: A {ra[0]:#x} ({ra[1]:#010x})  B {rb[0]:#x} ({rb[1]:#010x})"
        elif vals and ra[2] and rb[2] and ra[2] != rb[2]:
            fa = " ".join(f"{k}{r}={v:#x}" for k, r, v in ra[2])
            fb = " ".join(f"{k}{r}={v:#x}" for k, r, v in rb[2])
            bad = f"writeback differs at pc {ra[0]:#x}: A {fa}  B {fb}"
        if bad:
            diffs += 1
            print(f"\nDIVERGENCE {diffs} after {compared} matching records: {bad}")
            show("A", A, i, a.context)
            show("B", B, j, a.context)
            if diffs >= a.max_diffs:
                return 1
            if bad.startswith("writeback"):
                i += 1
                j += 1
                continue
            r = resync(A, B, i, j, a.window, a.resync_match)
            if r is None:
                print("could not resync within the window")
                return 1
            print(f"resynced after skipping {r[0]} A records and {r[1]} B records")
            i += r[0]
            j += r[1]
            continue
        compared += 1
        i += 1
        j += 1
    print(f"\n{compared} records matched; {diffs} divergences; stopped at end of {'A' if i >= len(A) else 'B'}")
    return 1 if diffs else 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
