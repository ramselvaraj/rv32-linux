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

## Directed tests (`directed/`, `make directed`)

Self-checking, DUT-only (Spike's CLINT timing and flat memory cannot model these). `tohost = 1` on success,
`(test << 1) | 1` on failure. Uses TB-only registers in `tb/sim_periph.sv`: CLINT+0xF000 drives MEIP/SEIP,
CLINT+0xF004 reads fine but every write returns a bus error.

* `irq.S`: MSI, MTI, MEI, SEI; priority MEI > MSI > MTI > SEI with all pending; `mstatus.MIE` masking; `mie`
  masking; SSI/STI via `mip`; SEI delegated through `mideleg` and taken in S-mode; vectored `mtvec`.
* `amo_write_error.S`: AMO whose read phase succeeds and whose write phase gets a bus error -> cause 7, mtval = address.

## Findings (`findings/`)

Two divergences from Spike were judged to be real core behaviour and are documented with reproducers instead of
being hidden: **F1** (access fault raised before the permission check for a PTE with a >32-bit PA; spec deviation,
low impact) and **F2** (a failing `sc.w` to an unmapped address does not fault; spec-ambiguous). No RTL was changed.

## Results (core @ HEAD)

| Run | Result |
|---|---|
| riscv-tests ISA, zero / random latency | 139 / 139 identical to Spike, both builds |
| `mix` `hazard` `mem` `muldiv` `amo` (750 progs, 800 instr) | all identical |
| `trap` (400 programs zero latency + 200 random latency) | all identical; every legal cause x privilege bin taken |
| `mmu` (400 + 150, both builds) | all identical; ~30% of virtual accesses fault (12, 13, 15); PTW bus-error and high-PPN windows covered |
| Directed (`irq`, `amo_write_error`), both builds | pass |

## Coverage (`cov/`, `make cov`)

* **Functional (retire-trace)**: 70/70 mnemonics (ecall/ebreak counted through their trap causes), 48/48 hazard bins
  (producer class x distance x operand), 33/33 legal trap-cause x privilege bins, 35 CSR addresses.
* **RTL (Verilator line + toggle)**: 84% of 1,181 coverage points over 1,690 programs. Every uncovered *line* is an
  unreachable FSM `default:` (3 places); the remainder is toggle coverage (high address/data bits that a 64 MiB
  testbench RAM never exercises).

## Mutation testing (`mutate/mutate.py`)

Each mutant is a one-line (or two-place) RTL bug; the core is rebuilt, the directed tests and the whole corpus run
against it, and it is killed if anything diverges from Spike or a directed test fails. The harness first checks that
the **unmodified** core passes everything (otherwise kills mean nothing) and excludes tests the core does not
support by design (`rv32mi-p-breakpoint`, `ma_data`).

**61 mutants, 56 killed, 5 survivors, all explained: no non-equivalent mutant survives.**

Classes covered: ALU, forwarding, load-use/AMO/CSR hazards, branches, `jalr`, divide/remainder, multiplier
signedness, register-file bypass, SC reservation, trap cause/tval/mepc/mstatus updates, privilege checks on CSRs and
xRET, PTE permission logic (U/SUM/MXR/A/D), page-table walker (reserved W-without-R, misaligned superpage), TLB
(superpage offset, tag aliasing), `sfence.vma`, interrupt priority/enable/delegation/masking/vectoring, AMO write-phase fault.

| Survivor | Why it survives |
|---|---|
| `md_div_neg_zero` | Equivalent: `neg_q` is dead when `by_zero` (it overrides the quotient) |
| `pte_sum_allows_exec` | Equivalent: instruction fetch calls `pte_ok(..., sum=0, ...)` and data accesses never have `acc == ACC_X` |
| `ptw_a_bit_ignored`, `pte_a_ignored_perm`, `ptw_d_bit_ignored` | The A/D check exists in both the walker and `pte_ok`; removing one copy is invisible. Removing both is killed (`ad_*_unchecked_everywhere`) |

## Gaps

* Interrupts are not part of the *random* lock-step programs (timing differs from Spike); they are covered by the
  directed tests only.
* The two memory models in the testbench have zero or 0-3 cycle random latency only.
* Toggle coverage is incomplete by construction (see above).
