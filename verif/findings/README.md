# Findings

Divergences between the core and the reference (Spike) that were judged to be core behaviour worth recording, as
opposed to harness artefacts or spec-allowed implementation choices (those are listed in `verif/README.md`).
Each has a self-contained reproducer; the lock-step checker flags it. **No RTL has been changed for any of them.**

| ID | Severity | Summary |
|---|---|---|
| F1 | low (spec deviation) | Access fault raised instead of page fault for a leaf PTE with PPN beyond 32-bit PA *and* insufficient permission |
| F2 | informational (spec-ambiguous) | A failing `sc.w` (no reservation) to an unmapped address fails silently; Spike raises an access fault |

## F1: PTW raises access fault before permission check

`f1_ptw_afault_precedence.S`: a 4 MiB leaf at VA 0x11000000 with PPN[1] bit set (PA >= 2^32), flags V|X|A (R=0).
An S-mode load should raise **load page fault (13)** (Sv32 step 5: permission violation -> page fault; the
PA-validity access fault only applies to a translation that succeeded). The core raises **load access fault (5)**.

Cause: in `rtl/core/rv_ptw.sv` the leaf branch checks `pte_hi` (`rsp_data[31:30]`) and sets `afault_q` at walk time,
before the core has applied R/W/X/U/SUM/MXR (`pte_ok` in `rv_core.sv`/`rv_fetch.sv`), which only runs after a TLB
fill. The same applies to instruction fetches (cause 1 vs 12) and stores (7 vs 15).

Suggested fix (not applied): do not fault in the walker for `pte_hi`; fill the TLB entry with a flag recording the
out-of-range PA, apply the permission check first, and raise the access fault only if the permission check passes.

Impact: none for Linux on this SoC (it never maps PA >= 4 GiB); matters only for compliance.

Reproduce: `gcc ... -T verif/cosim/link.ld verif/findings/f1_ptw_afault_precedence.S -o f1.elf && python3 verif/cosim/cosim.py build/sim/Vtb_top f1.elf`
(prints `MISMATCH ... dut x28=00000005 vs spike x28=0000000d`).

## F2: failing SC does not check the address

`f2_failing_sc_unmapped.S`: `sc.w x15, x6, (x0)` with no reservation. The core returns `x15 = 1` without issuing a
bus access, so there is no fault. Spike raises a store/AMO access fault (7) first. The A-extension text does not
clearly require an exception for an SC that is going to fail, so this is recorded rather than called a bug.
The random generator avoids this one encoding (`funct5 = 3` with `rs1 = x0`) to keep the regression free of noise.
