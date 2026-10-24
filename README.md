# rv32-linux: a readable Linux-capable RV32IMA core (SystemVerilog)

An in-order, 5-stage **RV32IMA_Zicsr_Zifencei** core with **M/S/U privilege** and an
**Sv32 MMU**, written to be small and readable, targeting a PYNQ-Z2 (Zynq-7020) and
mainline Linux. Verified in Verilator against the official `riscv-tests` and by booting
**OpenSBI** into an S-mode payload.

## Status

| Milestone | State |
|---|---|
| RV32I 5-stage pipeline, Verilator bench, `rv32ui` | done |
| M (mul/div) and A (LR/SC, AMO) | done, `rv32um`, `rv32ua` pass |
| Zicsr, traps, M/S/U, delegation, timer/soft interrupts | done, `rv32mi`, `rv32si` pass |
| Sv32 MMU (TLBs + hardware walker), `sfence.vma` | done, all `-v-` (virtual memory) variants pass |
| OpenSBI (`generic`, rv32) boots an S-mode payload | done: SBI calls, delegated timer irq, paging, page faults |
| Spike lock-step co-sim | next |
| Vivado block design on PYNQ-Z2 (core + PS7 DDR port) | next |
| Buildroot rootfs + Linux to a shell | next |

`make test` result: **139 / 139** ISA tests (zero and random memory latency) plus the custom
regressions in `sw/tests` and the OpenSBI boot. Three upstream tests are skipped on purpose:
`ma_data` (hardware misaligned access; OpenSBI emulates it instead) and `breakpoint` (debug
triggers).

## Layout

    rtl/core/    rv_core (pipeline), rv_fetch, rv_decode, rv_csr, rv_tlb, rv_ptw,
                 rv_muldiv, rv_dmux, rv_alu, rv_regfile, rv_pkg
    tb/          Verilator SoC: dual-port RAM, CLINT, 16550-style UART, testbench
    sw/          payload (S-mode test), DTS, test runners, OpenSBI build, patches
    docs/        design notes
    fpga/        PYNQ-Z2 project (not started)

## Quick start

    sw/setup_tools.sh        # RISC-V GCC, riscv-tests, OpenSBI into tools/ (gitignored)
    make test                # lint-clean build + riscv-tests ISA suite
    sw/build_opensbi.sh      # payload + DTB + OpenSBI -> build/fw_payload.hex
    make test-custom         # regressions + OpenSBI boot
    make test-lat            # everything again with random extra memory latency

Run something by hand:

    build/sim/Vtb_top +hex=build/fw_payload.hex +halt=<pc> +maxcycles=60000000 [+trace]

Requires Verilator (tested 5.052), a C++ compiler, `dtc`, `curl`, `git`, Python 3.

## PYNQ-Z2 plan

The DDR3 is wired to the ARM PS, not the fabric, so there is no soft DRAM controller:

    RV32 core (PL) --AXI4--> Zynq PS7 S_AXI_HP0 --> DDR3
    ARM (PYNQ Linux) loads OpenSBI + kernel + initramfs into a reserved DDR window,
    then releases the RV32 core's reset through an AXI-GPIO register.

Console: a UART in the fabric on Pmod/Arduino pins, or a shared-memory ring read by the ARM.
Both core buses use a small req/rsp protocol (see `docs/DESIGN.md`) that bridges to AXI.
