---
name: chipyard-verilator-sim
description: Build, run and sweep Chipyard Verilator RTL simulators (simulator-chipyard.harness-CONFIG binaries), and read their verdicts correctly. Use this whenever the task involves building a Chipyard config with Verilator, running a RISC-V test or benchmark on an RTL simulator (bare-metal or under pk), sizing +max-cycles/timeouts, running many tests in parallel, pausing/resuming a sweep, or deciding whether a sim result is a real failure, a hang, or a harness artifact, even if the user just says "run the tests on the RTL" or "rebuild the sim".
---

# Chipyard Verilator simulation

Scripts live in `scripts/` next to this file. All take `--help`.

| Script | Does |
|---|---|
| `build.sh` | builds a config's simulator (fast or debug/waveform), guards memory, copies the binary out of the tree |
| `run_test.sh` | runs one program, writes a log, prints `NAME,VERDICT,WALL_S,CYCLES,LOG` |
| `sweep.sh` | runs a job list in parallel under a machine-wide cap; resumable |
| `pause.sh` | pauses / drains / resumes a sweep |
| `summarize.sh` | latest verdict per test, counts, non-PASS list |

Before anything heavy, check the machine (`uptime`, `free -g`, who else is running sims) and any
resource rules the user has set. A Verilator build of a large SoC takes several GB of RAM per
FIRRTL/Verilator process and minutes to hours; a sim is one core per Verilator thread.

## Build

```
scripts/build.sh --chipyard <checkout> --config <CONFIG> [--package <PKG>] [--threads N] [--fst] --out <dir>
```

- `--threads` = `VERILATOR_THREADS`. Use 1 for sweeps (many sims, one core each). Use several
  only when a single sim runs alone. Verilator worker threads spin, so an N-thread sim burns N
  cores even when it gains little.
- The thread count is compiled in, but Chipyard's make does not rebuild the model when only
  `VERILATOR_THREADS` changes; it silently relinks the old one. `build.sh` deletes the model
  directory when its recorded `--threads` differs.
- `--fst` / `--vcd` build the `-debug` simulator for waveforms (see the verilator-fst-waveforms
  skill). It is a different binary; keep the fast one for verdicts.
- Copy the result out of the tree (`--out`). Sweeps that run straight from
  `sims/verilator/simulator-*` break or silently change when someone rebuilds.
- Do not edit sources while a build runs, and do not trust a binary's mtime as proof it contains
  an edit (mtime is link time). `build.sh` warns when a `.scala` file is newer than the
  generated Verilog.
- Never start several make-based runs of the same config in parallel: each may re-elaborate and
  they OOM each other; the failure reads like a test failure. Build once, then fan out.

## Run one program

```
scripts/run_test.sh --sim <sim> --elf <elf> [--pk <pk>] [--max-cycles N] [--timeout S | --cpu-limit S] [--quiet] [--chipyard <checkout>]
```

What the plusargs mean, and the traps that make results silently wrong, are in
`references/plusargs-and-verdicts.md`. Read it before writing your own invocation. The short
version:

- `+loadmem=<elf>` is needed for any realistic run time; without it the program is loaded over
  the slow TSI link and almost everything times out. `run_test.sh` always passes it.
- Under pk, the pk ELF is what gets loaded (`+loadmem=<pk>`), and the program follows pk.
- `run_test.sh` passes `+verbose` by default, because a passing run prints its cycle count
  (`*** PASSED *** Completed after N simulation cycles`) only with it. `--quiet` drops it, for
  designs whose printfs (commit logs, debug prints) would flood the log. The verdict comes
  from the exit code either way.
- `+dramsim` changes timing, not function. Use it only when comparing against cycle numbers
  taken with it; match the campaign you compare against.
- `+max-cycles` counts HARNESS cycles. The generated TestDriver prints `after N simulation
  cycles` in the same unit.

## Verdicts

| Verdict | Meaning | Trust |
|---|---|---|
| PASS | exit 0, no FAILED line | real |
| FAIL(tohost=N) / FAIL(exitcode=N) | program reported failure (riscv-tests: N is the test number) | real |
| CYCLE_TIMEOUT | hit `+max-cycles` | real hang or bound too small |
| ASSERT | RTL assertion or simulator error | real |
| WALL | wall-clock `--timeout` | unmeasured: load, pauses, or a hang |
| CPU_LIMIT | `--cpu-limit` reached | slow or hung; not load-dependent |
| OTHER_rc | anything else | read the log |

Report every non-PASS class separately. A PASS/FAIL-only summary hides asserts and timeouts.
Treat WALL as "not measured", never as a hang, until it reproduces with a bigger bound on a quiet
machine. A killed simulator can still print `*** PASSED ***`; check the timeout exit code first
(the script does).

Size bounds from a known-good run of the same test (about 10x its cycles or time), not from a
throughput guess. A `+max-cycles` the sim cannot reach inside the wall limit makes CYCLE_TIMEOUT
impossible and turns every slow test into a false WALL.

## Sweep

```
scripts/sweep.sh --jobs jobs.txt --out <dir> --parallel P [--global-cap N] -- --sim <sim> --cpu-limit 3600 --max-cycles 0
```

`jobs.txt`: `NAME ELF [extra run_test.sh args]` per line. Results go to `<dir>/results.csv`
(append-only; the latest row per test wins), logs to `<dir>/logs/`, and a `<NAME>.done`
marker per finished job.

- `--parallel P` caps this sweep's own simulators. Change it live with `echo N > <dir>/cap.txt`.
- `--global-cap N` additionally waits while N or more simulators run on the whole machine,
  anyone's, matched by program name with `--sim-regex`. Use it on a shared machine that has
  an agreed total; leave it off when other people's sims should not block yours.
- Rerunning the same command resumes; to redo a job, delete its `.done` and rerun.
- Prefer `--cpu-limit` over `--timeout` in sweeps. Wall time grows with machine load and keeps
  running while a sim is paused, so wall limits produce false WALLs whenever the machine is busy
  or the sweep is paused. Keep a large `--timeout` too, as a backstop.
- Pause: `pause.sh --out <dir>` (SIGSTOP + no launches), `--drain` (let running ones finish),
  `--resume`. Paused sims still hold their RAM.
- `summarize.sh <dir> --list` for counts and the non-PASS list.

## Operating rules that prevent wrong results

- Kill only by PID, after checking the PID is yours. `pkill -f <pattern>` also matches the
  shell that runs it, and name matches hit other people's sims.
- Do not edit a running script in place. Bash reads scripts incrementally, and running copies
  execute the edited bytes. Copy to a new name instead.
- Start long jobs detached (`setsid nohup ... < /dev/null &`), and give every background job
  `< /dev/null`; a backgrounded sim inside `while read` eats the job list.
- "Process alive" is not "progressing": check that the log grows. Redirected sim stdout is
  block-buffered, so a quiet log during a run proves nothing; read it after the run.
- An impossible verdict on known-good code means the harness is wrong. Before blaming the RTL
  for a broad regression, re-run one known-good test on a known-good binary.
- Randomized register/memory init (`RANDOMIZE_*`) means any RTL change shifts cycle counts a few
  percent on short tests. That is noise, not a performance change; `--seed N` varies it.
