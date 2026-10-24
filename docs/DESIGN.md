# Design notes

## Pipeline

    F  rv_fetch   PC, iTLB, 4-entry queue, one request in flight, discards on redirect
    D  rv_decode  decode + register read (write-through bypass from W)
    X  ALU, branch/jump resolve, rv_muldiv (2-cycle mul, 34-cycle restoring div), forwarding
    M  load/store, dTLB, atomics, CSR access, ALL trap / xRET / fence.i / sfence commit
    W  register write-back, retire trace

Branches are predicted not-taken and resolved in X (flushes F and D). Forwarding sources are
the M and W stages; loads, CSR reads, LR/SC and AMOs forward only from W (one stall).

**Precise traps in M.** An exception is attached to its instruction (fetch fault, illegal
instruction, misaligned target from X, page/access/alignment fault from M) and taken when
that instruction reaches M. Everything older has already retired and nothing younger has
touched state, so no rollback is needed. Interrupts are taken at the same point, before the
instruction in M starts. `mret`/`sret`/`fence.i`/`sfence.vma`/`satp` writes redirect the same way.

## Bus protocol (instruction and data port)

    req_valid, req_ready      request accepted when both are high
    rsp_valid, rsp_data/err   response, in order, at least one cycle later
    a new request may be accepted in the cycle the previous response returns

`req_valid` may be withdrawn before `req_ready` (fetch redirect), so an AXI bridge must latch
a request before presenting it. The data port is shared by the LSU and the page-table walker
(`rv_dmux`, LSU has priority). Stores wait for their response before retiring, so `fence.i`
only needs to flush the pipeline.

## MMU

Sv32, 4 KiB and 4 MiB pages, separate fully-associative iTLB (4) and dTLB (8), one shared
walker. No ASIDs (the field reads zero), so `sfence.vma` and `satp` writes flush everything.
The walker is read-only: A=0, or D=0 on a store, raises a page fault and software updates the
PTE (Svade behaviour, which Linux supports). Physical addresses are 32-bit; PPN[21:20] != 0
is an access fault. PMP registers exist and are writable but not enforced.

## Not implemented

C/F/D extensions, hardware misaligned access (traps; OpenSBI emulates), debug triggers,
PMP enforcement, ASIDs, hardware A/D update, `wfi` stalling (it is a no-op).
