# Verification

Lock-step co-simulation of the RV32IMA core against [Spike](https://github.com/riscv-software-src/riscv-isa-sim),
constrained-random program generation, and mutation testing of the checker itself.

```
make cosim            # 139 riscv-tests ISA ELFs, retire-by-retire vs Spike
make cosim-lat        # same, with random 0-3 cycle extra memory latency
make cosim-random     # random programs, 5 profiles, both memory-latency builds
make mutate           # inject RTL bugs, check the co-sim kills them
```

Needs Spike built with commit logging (`--log-commits`):
`git clone https://github.com/riscv-software-src/riscv-isa-sim && cd riscv-isa-sim && git submodule update --init && mkdir build && cd build && ../configure --prefix=$HOME/builds/spike-cl && make -j && make install`
(set `SPIKE=` to override the path; distro packages are often built without commit logging).

## What is compared

For every retired instruction: PC, instruction word, and the integer-register write (including
that `x0` is never written). The core's `trace_*` port (see `tb/tb_top.sv`, `+trace`) is the DUT side;
Spike's `--log-commits` is the reference.

## Known, intentional differences (masked in `cosim/cosim.py`)

| Difference | Why it is not a bug |
|---|---|
| `cycle/time/instret/hpm` CSR read values | A cycle-accurate core and an ISS count differently; PC/insn still compared |
| `mvendorid/marchid/mimpid` values | Implementation-defined; Spike reports its own IDs |
| `mstatus/sstatus` SD/FS/XS/VS bits | Spike keeps FS live without F; this core hardwires them to 0. Masked on status reads, and on loads of a spilled copy (differences confined to SD/FS only) |
| Spike runs past `tohost` in the `v` tests | `tohost` is written via a virtual address there; a DUT PASS plus full-length match is accepted |

Spike must be given `zicntr` (`rv32ima_zicsr_zifencei_zicntr`): without it Spike traps on `csrc cycle, zero`
that `rv32mi-p-zicntr` requires to succeed.

## Random programs (`cosim/gen_random.py`)

Constrained-random RV32IMA, M-mode, trap-free, forward-only control flow so every program ends.
Register pool x5..x15 forces RAW/WAW hazards; values biased to corner cases (0, -1, INT_MIN/MAX, powers of two);
a few hot memory words force store-to-load forwarding. Profiles: `mix`, `hazard`, `mem`, `muldiv`, `amo`.
Covers ALU/shift/slt, M extension (div-by-zero, overflow), all load/store sizes, branches, `jal`, `jalr`
(incl. LSB clearing), AMOs, LR/SC (same address, other address, no LR, store between, double SC), CSR, fences.

## Results (core @ HEAD)

| Run | Result |
|---|---|
| riscv-tests ISA, zero latency | 139 / 139 identical to Spike |
| riscv-tests ISA, random latency | 139 / 139 identical to Spike |
| Random programs (5 profiles x 150, 800 instr), zero latency | 750 / 750 identical (~600k instr) |
| Random programs (mix/mem/amo x 100), random latency | 300 / 300 identical |
| Mutation testing (22 RTL bugs) | 21 killed; 1 survivor is an equivalent mutant (`neg_q` is dead when `by_zero`) |

Mutants span ALU (slt/sltu/sra/sll/sub), forwarding (priority, missing W/M paths), load-use / AMO / CSR
late-result hazards, branch compare (blt/bge/bne), `jalr` LSB, divide-by-zero, REM sign, MULH/MULHSU/MULHU
signedness, register-file bypass, and SC reservation address. Two generator gaps were found by surviving
mutants (no `jalr`, no mismatched-address SC) and fixed.

## Not covered yet

Random programs are trap-free and M-mode only: privilege transitions, page faults and the MMU are exercised
only by the riscv-tests. No functional coverage model yet. Interrupts (timer/software) are not randomized.
