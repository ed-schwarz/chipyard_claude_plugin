# Plusargs and verdict details

## Command line shape

```
<sim> +permissive [plusargs...] +permissive-off <loaded-elf> [program args]
```

Everything between `+permissive` and `+permissive-off` goes to the harness. The first argument
after `+permissive-off` is the binary fesvr runs. Plusargs placed after it, or before
`+permissive`, are either ignored or taken as the binary.

| Plusarg | Effect |
|---|---|
| `+loadmem=<elf>` | preloads the ELF into DRAM. Without it, fesvr loads over TSI at a few bytes per cycle. |
| `+max-cycles=N` | ends with `*** FAILED *** (timeout)` after N harness cycles. 0 or absent = no bound. |
| `+verbose` | turns on Chisel `printf`s (commit logs, debug prints) and the `*** PASSED ***` line. Output goes to stderr and can be huge. |
| `+dramsim` | DRAMSim2 timing model instead of the magic (fixed-latency) memory. Needs `+dramsim_ini_dir=<chipyard>/generators/testchipip/src/main/resources/dramsim2_ini` unless run from a directory holding `dramsim2_ini/`. |
| `+verilator+seed+N` | changes the random initial values of registers and memories. Must be inside the `+permissive` block. |
| `+vcdfile=<file>` | debug simulator only: writes the waveform (VCD, or FST when built with `USE_FST=1`). |
| `+dump-start=N` | does not delay dumping in Verilator: `$dumpvars` starts at time 0. Only `+max-cycles` bounds a waveform. |

## Proxy kernel (user-mode programs)

```
<sim> +permissive +loadmem=<pk> [..] +permissive-off <pk> <program> [args]
```

pk itself is preloaded; pk then reads the program over the host interface. User-mode programs can
run much longer than the same work bare-metal, because of pk start-up and
syscalls (measured 27-30x on short vector tests). A pk run that fails prints `*** FAILED *** (exit code = N)` from SimTSI. N is the
program's exit status; a very large N usually means the program trapped.

## Exit status and output

| Simulator outcome | Output | rc |
|---|---|---|
| pass | `$finish` (plus `*** PASSED *** Completed after N simulation cycles` with `+verbose`) | 0 |
| riscv-tests failure | `*** FAILED *** (tohost = N)` | non-zero |
| cycle bound | `*** FAILED *** (timeout) after N simulation cycles` (many spaces before `(timeout)`; grep for `(timeout)` alone) | non-zero |
| RTL assertion | `Assertion failed` ... | non-zero |
| killed by `timeout` | nothing, or a truncated log; rc 124 | 124 |
| killed by SIGTERM from elsewhere | may still print `*** PASSED ***` | varies |

For riscv-tests (and suites built on its `TEST_CASE` macros), `tohost = N` is the failing test
number. Find `li gp,N` in the disassembly (`<elf>.dump`) and walk back to the instruction under
test. The `beq` that compares the result with the golden value has the DUT value and the
expected value as its two operands.

## Units

- Harness cycles vs core cycles: the harness clock and the core clock can differ (often the core
  runs at half the harness rate in simulation time). `+max-cycles` and the `after N simulation
  cycles` line both use harness cycles. Use the program's own cycle counter (`rdcycle`/`mcycle`)
  for core-cycle performance numbers.
- Comparing cycles between two runs is only meaningful with the same memory model, the same
  plusargs and the same binary. Short tests carry several percent of noise from randomized
  initial state whenever the RTL changes.
