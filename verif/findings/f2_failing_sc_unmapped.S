# F2: a store-conditional with no reservation, to an unmapped address.
# Spike raises a store/AMO access fault (7) even though the SC would fail; this core fails the SC (rd=1) without
# touching the bus, so no fault. The A-extension text is loose about whether a failing SC must still raise
# address exceptions, so this is a spec-ambiguity finding, not a clear bug.
  .section .text.init,"ax"
  .globl _start
_start:
  la   x29, handler
  csrw mtvec, x29
  li   x6, 1
  sc.w x15, x6, (x0)                   # Spike: cause 7, core: x15 = 1
  li   x30, 1
  la   x29, tohost
  sw   x30, 0(x29)
1: j 1b
handler:
  csrr x28, mcause
  csrr x29, mepc
  addi x29, x29, 4
  csrw mepc, x29
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
