---
name: verilator-fst-waveforms
description: Capture and analyze Verilator waveforms (FST/VCD) from Chipyard or other Verilator testbenches without a GUI, by listing signals, dumping per-cycle tables at a clock edge, and counting how often or how long a signal is high. Use this whenever the task involves tracing an RTL bug in a waveform, building a debug/tracing simulator, finding a signal's hierarchical name, measuring throughput or latency from a trace, or reading a .fst/.vcd file, even if the user only says "look at the waves" or "trace it".
---

# Verilator waveforms (FST)

Scripts are in `scripts/`:

| Script | Does |
|---|---|
| `build_fstq.sh` | compiles `fstq` (a tiny FST reader) from Verilator's bundled `fstapi.c`; run once per machine |
| `fstq` | `fstq <f> info`, `fstq <f> list <substr>...`, `fstq <f> dump <t0> <t1> <handle>...` |
| `fst_table.py` | `info`, `list`, and `table` (per-cycle samples at a clock edge, filters, high-count) |

`fst_table.py` looks for `fstq` next to itself, then in `$FSTQ`, or takes `--fstq PATH`.

## 1. Get a trustworthy trace

1. Build the debug simulator with FST output. In Chipyard that is `make debug USE_FST=1
   CONFIG=...`, which produces `simulator-...-<CONFIG>-debug`. With the chipyard-verilator-sim
   skill: `build.sh --fst`.
2. Before trusting the trace, run the same test on the fast simulator and the debug simulator
   and compare their verdicts. Tracing changes how Verilator schedules and optimizes the model.
   In a design with latent bugs this can move which bug appears, or hide it completely. If the
   verdicts differ, the trace describes a different execution. Use `printf` debugging in the
   fast build instead, or pick a test where both agree.
3. Bound the capture with `+max-cycles` (harness cycles). In Chipyard's TestDriver,
   `+dump-start` does not delay dumping (`$dumpvars` starts at time 0), so a late window still
   dumps everything before it. Run one capture to the latest cycle you need, then analyze any
   window inside it. Expect several KB per cycle for a full SoC; check free disk first.
4. Run: `+vcdfile=<out>.fst` inside the `+permissive` block (`run_test.sh --wave out.fst`).

## 2. Find signals

```
fst_table.py t.fst info
fst_table.py t.fst list rob commit valid        # every path containing all three substrings
```

Paths are full hierarchical names (`TOP.TestDriver.testHarness...`). Chisel names usually
survive into the Verilog (`io_*`, register names), but intermediate wires may be renamed
(`_GEN_*`, `_T_*`) or optimized away. If a signal you expect is missing, look for its
register, or the port of the module that consumes it.

Verilator aliases identical signals: one handle can appear under several scopes. Identify a
signal by its full path, never by handle → name.

## 3. Tabulate

```
fst_table.py t.fst table --clock 'core,clock' --sig 'rob.io_commit_valids_0' \
    --sig 'rob.io_commit_uops_0_debug_pc' --when io_commit_valids_0 [--t0 T --t1 T] [--changes]
```

- A spec is comma-separated substrings. A spec whose last part matches a full signal name
  exactly wins over partial matches; an ambiguous spec stops and lists the candidates (or use
  `--all-matches`).
- Values are sampled just before each clock edge: the values the flops capture on that edge.
  This is the right view for "what did this stage see in this cycle".
- `edge` is the edge index from `--t0`. The time column is in FST units (`info` prints the
  timescale). In Chipyard the core clock and the harness clock can have different periods;
  find the period from two consecutive edges.
- `--when SIG` keeps only cycles where SIG is non-zero; `--changes` drops repeated rows.

## 4. Count, don't eyeball

```
fst_table.py t.fst table --clock 'core,clock' --sig '<1-bit signal>' --count
```

This prints cycles high and the longest run of consecutive high cycles. Count by sampling the
level every cycle, not by counting rising edges: a signal that fires on consecutive cycles stays
high, so edge counting merges a burst of N events into one and undercounts the fastest case.

For a latency or throughput claim, also state the baseline it is compared against.

## Lookups that return the wrong thing

The costly mistakes in waveform work are lookups that return a plausible but wrong answer:
the wrong signal with a similar name, an address off by a page, a test number decoded wrongly.
After any lookup, check the key as well as the value: print the full path next to the value,
re-derive an address a second way, and confirm which test or instruction a time window
belongs to (for example with the commit PC at that time).
