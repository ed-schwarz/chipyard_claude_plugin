---
name: spike-commit-diff
description: Find the first instruction where an RTL core's execution diverges from the spike ISA simulator, by producing a commit log from the RTL simulation and an instruction/commit log from spike, then aligning and diffing them. Use this whenever an RTL test fails, hangs or gives a wrong result and you need to know which instruction went wrong first, when checking an RTL core against spike as a golden model, or when the user mentions commit logs, spike -l, --log-commits, or "compare against spike", even if they only say "find where it goes wrong".
---

# RTL commit log vs spike

`scripts/commit_diff.py A.log B.log` aligns two logs and reports the first divergence with
context. It reads:

- spike `-l` lines: `core   0: 0x<pc> (0x<inst>) <disasm>`
- spike `--log-commits` lines: `core   0: <priv> 0x<pc> (0x<inst>) x<rd> 0x<value> ...`
- spike-style RTL commit logs: `<priv> 0x<pc> (0x<inst>) [x<rd> 0x<value>]` (Rocket with
  `enableCommitLog`, BOOM with its commit-log config fragment)
- Rocket's default per-cycle trace: `C0: <cycle> [<valid>] pc=[..] W[r<rd>=<val>][<wen>] ... inst=[..]`

When a log has priv-format lines, other `0x.. (0x..)` lines in it are ignored, so a spike log
with both `-l` and `--log-commits` output is not double-counted.

## 1. RTL commit log

The core must print one line per committed instruction. Find the option in the core's
generator: Rocket has `enableCommitLog` (otherwise it prints the per-cycle `C0:` trace), and BOOM
has a commit-log config fragment (`WithBoomCommitLogPrintf`). Build that config, then run with
`+verbose`. Chisel printfs only print under `+verbose`, and they go to stderr:

```
<sim> +permissive +verbose +loadmem=<elf> [+max-cycles=N] +permissive-off <elf> 2> rtl.log
```

The log is large: roughly 40-60 bytes per instruction. Bound the run with `+max-cycles` just past
the failure point, and check free disk space first.

## 2. Spike log

```
spike --isa=<isa> -l --log-commits [-m<mem>] [<pk>] <elf> 2> spike.log
```

- `--isa` must describe the same machine as the RTL config: base and extensions (for example
  `rv64gc`, `rv64gc_zba_zbb`, or `rv64gcv_zvl256b` for vectors with VLEN 256). A mismatched ISA string
  produces a divergence at the first instruction that differs, which looks like an RTL bug.
- Use the same pk binary for both runs when running under pk.
- Memory size and layout affect pk's page allocation and the addresses it hands out. Load and
  store values can then differ while control flow still matches.
- The device tree differs. The RTL boots with the SoC's device tree (Chipyard writes it as
  `generated-src/<...>/<...>.dts`), spike with its own. pk parses it in machine mode, so string
  and tree-walk loops (`strlen`, `strcmp`, `fdt_scan_*`) run a different number of times and
  the logs diverge within the first thousand instructions. That is expected. Either give spike
  the RTL's tree (`dtc -I dts -O dtb x.dts -o x.dtb`, then `spike --dtb=x.dtb`, if spike accepts
  its devices), or align past it with `--start-pc` at the supervisor entry, the program entry or
  `main`.
- The boot ROMs differ (Chipyard at 0x10000, spike at 0x1000). The default alignment at the first
  common (pc, instruction) pair skips them.
- Program arguments, file paths and environment strings that differ between the runs change
  string lengths the same way. Use the same argv.

## 3. Diff

```
scripts/commit_diff.py rtl.log spike.log [--start-pc 0x80000000] [--max-diffs 5] [--no-values]
```

- Alignment defaults to the first (pc, instruction) pair present in both logs. `--start-pc` aligns
  both at the first commit of a given PC, such as the program entry or `main`.
- Each record is compared on PC and instruction, then on the written register value when both
  logs have one. `--no-values` compares control flow only.
- After a divergence, `--max-diffs N` resyncs on the nearest common (pc, instruction) pair and
  continues. Use this to skip known benign differences (start-up strings, timer interrupts)
  and reach the real one.
- `--ignore-pc 0xA,0xB` or `--ignore-pc 0xA-0xB` drops records at those PCs from both logs. Use it
  for busy-wait loops whose iteration count depends on timing.
- Exit status is 0 when no divergence is found.

## Reading the result

- The first divergence that is not explained by the setup differences above is the suspect.
  A wrong value usually shows up one or more instructions before the control-flow change it
  causes; look at the writebacks just before the branch that went the other way.
- Host-interface polling is timing-dependent. pk's HTIF syscall path writes `tohost` and spins
  on `fromhost` (a two-instruction `ld`/`beqz` loop) until the host answers; the spin count
  differs on every run. Find the loop's PCs in the first such divergence and pass them to
  `--ignore-pc`.
- Interrupts (timer, external) are not deterministic between RTL and spike. A divergence that
  enters a trap handler on one side only is usually an interrupt-timing difference; resync
  past it.
- Instructions whose results the RTL log cannot show (vector registers, CSRs, loads whose data
  arrives late, printed as `0xXXXX...`) are compared on PC/instruction only. A wrong vector
  result surfaces later, where a scalar reads it back or a branch depends on it.
- Confirm the suspect instruction against the disassembly (`riscv64-unknown-elf-objdump -d`)
  before building a theory: check that the PC is in the function you think it is.
