# Overnight verification run: plan and status

Goal: verify the user's existing designs "all out" (Verilator/Spike/formal; no FPGA needed, no VCS on this machine).
Rules: commit locally in small steps; DO NOT push without the user saying so; if a real RTL bug appears, document it
(minimal repro + root cause) and move to the next item instead of silently changing the design; never claim a number
that was not measured. Record what actually ran in the Log below. Tools: Spike with commitlog at ~/builds/spike-cl/bin/spike,
Verilator 5.052, RISC-V gcc at rv32-linux/tools/gcc. sudo password is NOT stored; ask via request_secret only if essential.

Repos (all under /mnt/windows/Users/ramse): linux_projects/rv32-linux, riscv/RAPTOR-SoC, riscv/riscv (pipeline + cache CPUs),
XLR8, addv-labs, addv-labs-showcase. Skip anything needing VCS or the board; list it under "Blocked" instead.

## Queue (work top to bottom; tick when done)
- [x] 1. rv32-linux: Spike lock-step co-sim, random generator, mutation testing (pushed as 1b8d4ff)
- [x] 2. rv32-linux: random programs with traps (ecall, illegal insn, misaligned, access faults), privilege M/S/U transitions, then Sv32 MMU (random page tables, page faults, sfence) and timer/software interrupts; keep lock-step vs Spike
- [ ] 3. rv32-linux: functional coverage model (ISA x hazard, trap causes, TLB hit/miss/flush) and a coverage report; add more mutants (CSR, MMU, trap logic), target 95%+ mutant kill
- [ ] 4. riscv/riscv pipeline + cache CPUs: riscv-arch-test or Spike lock-step; document results honestly
- [ ] 5. Formal with SymbiYosys/yosys on the async FIFO and DMA control (install without sudo if possible, e.g. OSS CAD Suite tarball in ~/builds)
- [ ] 6. RAPTOR-SoC GPU: random kernels for the 16-bit ISA vs the Python reference; CDC checks with available tools
- [ ] 7. AXI4 DMA: expand mutants from 18 to 40+ and publish a bug-catch matrix
- [ ] 8. Per-repo VERIFICATION.md with measured numbers; update resume bullets draft (do not edit resumes without being asked)

## Blocked (needs the user)
- UVM testbench on VCS (no vcs here); hardware stress on XLR8 and UART shell fix (need the board); pushing commits.

## Log (append newest at the bottom: date/time, item, what was run, measured result, next step)
- 2026-11-18: Item 1 done. 139/139 riscv-tests identical to Spike (zero + random latency); 1050 random programs identical;
  mutation 21/22 killed (survivor is equivalent). Documented Spike divergences in verif/README.md.
- 2026-11-18 (night): Item 2 done. Added `trap` and `mmu` generator profiles (handler checks mcause/mtval/mstatus/mepc lock-step; U/S blocks; Sv32 with random PTEs, SUM/MXR, sfence, fetch faults). 700 trap + 550 mmu programs identical to Spike on zero- and random-latency builds; no RTL bugs found. Generator/harness bugs found and fixed on the way (stale exit magic in handler, ROM filter, Spike --instructions semantics). One documented spec-allowed divergence added (illegal tval for 16-bit-parcel encodings). Mutants: 54, baseline clean, 48 killed, survivors explained in verif/README.md (pte_sum_allows_exec being re-checked with --full corpus). Next: item 3 (coverage model + more mutants).
