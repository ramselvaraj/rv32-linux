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
| `mtval` of an illegal word with low 2 bits != 11 | Spike reports the 16-bit parcel, this core (no C ext) the whole 32-bit word; the privileged spec allows both |
| Spike runs past `tohost` in the `v` tests | `tohost` is written via a virtual address there; a DUT PASS plus full-length match is accepted |

Spike must be given `zicntr` (`rv32ima_zicsr_zifencei_zicntr`): without it Spike traps on `csrc cycle, zero`
that `rv32mi-p-zicntr` requires to succeed.

## Random programs (`cosim/gen_random.py`)

Constrained-random RV32IMA with forward-only control flow so every program ends. Register pool x5..x15 forces
RAW/WAW hazards; values biased to corner cases (0, -1, INT_MIN/MAX, powers of two); a few hot memory words force
store-to-load forwarding. Profiles:

| Profile | What it adds |
|---|---|
| `mix`, `hazard`, `mem`, `muldiv`, `amo` | M-mode, trap-free: ALU/shift/slt, M extension (div-by-zero, overflow), all load/store sizes, branches, `jal`/`jalr` (LSB clearing), AMOs, LR/SC (same address, other address, no LR, store between, double SC), CSR, fences |
| `trap` | An M-mode handler that reads `mcause`/`mtval`/`mstatus`/`mepc` (all compared lock-step) and skips the instruction. Traps: ecall (U/S/M), ebreak, illegal words, illegal/ro-CSR access, `mret`/`sret` below M, misaligned load/store/AMO/jump, load/store/AMO/instruction access faults. Random U/S privilege blocks via `mret` and back via an exit `ecall` |
| `mmu` | Everything in `trap` plus Sv32: a root table with a 4 KiB-page window (16 pages), an aligned 4 MiB leaf and a misaligned 4 MiB leaf; random V/R/W/X/U/A/D per PTE (including reserved W-without-R); random `mstatus.SUM`/`MXR`; PTEs rewritten and `sfence.vma` between blocks; loads/stores/AMOs and instruction fetches (`jalr` into virtual pages whose 16-byte groups start with `ret`) in S/U mode |

## Results (core @ HEAD)

| Run | Result |
|---|---|
| riscv-tests ISA, zero / random latency | 139 / 139 identical to Spike, both builds |
| `mix` `hazard` `mem` `muldiv` `amo` (750 progs, 800 instr) + 300 random-latency | all identical |
| `trap` (700 programs, both latency builds) | all identical; causes 0,2,3,4,5,6,7,8,9,11 all taken |
| `mmu` (550+ programs, both latency builds) | all identical; ~30% of virtual accesses fault (causes 12, 13, 15) |
| Mutation testing | see below |

## Mutation testing (`mutate/mutate.py`)

Each mutant is a one-line (or two-place) RTL bug; the core is rebuilt and the whole corpus is run against Spike.
A mutant is killed if any program diverges. The harness first checks that the **unmodified** core passes the corpus
(otherwise kills mean nothing) and excludes tests the core does not support by design (`rv32mi-p-breakpoint`, `ma_data`).

Classes covered: ALU, forwarding, load-use/AMO/CSR hazards, branches, `jalr`, divide/remainder, multiplier
signedness, register-file bypass, SC reservation, trap cause/tval/mepc/mstatus updates, privilege checks on CSRs and
xRET, PTE permission logic (U/SUM/MXR/A/D), page-table walker (reserved W-without-R, misaligned superpage), TLB
(superpage offset, tag aliasing), `sfence.vma`.

Survivors, all explained:

| Survivor | Why it survives |
|---|---|
| `md_div_neg_zero` | Equivalent: `neg_q` is dead when `by_zero` (it overrides the quotient) |
| `ptw_a_bit_ignored`, `pte_a_ignored_perm`, `ptw_d_bit_ignored` | The A/D check is duplicated (walker and `pte_ok`); each alone is redundant. Removing both is killed (`ad_*_unchecked_everywhere`) |
| `trap_amo_fault_cause` | Needs a bus error on the *write* phase of an AMO after a successful read; Spike's flat memory cannot provoke it. Needs an error-injecting bus model |
| `pte_sum_allows_exec` | See Gaps (rare S-mode fetch from a U page with SUM=1) |

## Gaps

No functional coverage model yet (next). Interrupts are not randomized. The two memory models in the testbench have
zero or 0-3 cycle random latency only.
