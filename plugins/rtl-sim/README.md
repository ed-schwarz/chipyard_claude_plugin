# rtl-sim: Claude Code skills for RTL simulation

A Claude Code plugin with three skills for working with Chipyard and Verilator RTL simulators.

| Skill | Use it for |
|---|---|
| `chipyard-verilator-sim` | Building a config's simulator, running one program bare-metal or under pk, running many tests in parallel, pausing and resuming a sweep, and reading verdicts (PASS, FAIL, cycle timeout, wall/CPU limit, assert) correctly |
| `verilator-fst-waveforms` | Finding signals in an FST trace, per-cycle tables sampled at a clock edge, and counting how many cycles a signal is high and its longest run |
| `spike-commit-diff` | Aligning an RTL commit log with a spike log and reporting the first instruction where they diverge, skipping known benign differences |

Claude loads a skill when a task matches it. You can also ask for one by name, for example
"use rtl-sim:chipyard-verilator-sim to run these tests".

## Install

```
/plugin marketplace add ed-schwarz/chipyard_claude_plugin
/plugin install rtl-sim@rtl-sim-tools
```

To update, run `/plugin marketplace update rtl-sim-tools`.

## Requirements

- Linux with bash, coreutils, `flock`, `timeout`, `setsid` and Python 3
- A Chipyard checkout with its environment set up (`env.sh`), for building simulators
- Verilator, for building the FST reader. The first time you use the waveform skill, run
  `skills/verilator-fst-waveforms/scripts/build_fstq.sh` (it compiles `fstq` from Verilator's
  bundled `fstapi.c`). Pass `--verilator-root` if `verilator` is not on `PATH`.
- spike, for the commit-log diff

## What the scripts do

Everything runs on your machine, as you, through the scripts in each skill's `scripts/` folder.
Each script prints its options with `--help`.

- `build.sh` runs `make` in the Chipyard checkout you name. It writes to that checkout's
  `sims/verilator` directory, as a normal Chipyard build does. It may delete a stale model
  directory under `generated-src/` that was built with a different `VERILATOR_THREADS`.
- `run_test.sh` and `sweep.sh` start simulators and write logs and results to the directory
  you give them.
- `pause.sh` stops and continues only the processes its own sweep started, by PID.
- `fst_table.py` and `commit_diff.py` only read the files you pass them.

Nothing is sent over the network.
