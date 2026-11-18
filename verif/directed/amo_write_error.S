# AMO whose read phase succeeds and whose write phase gets a bus error.
# TB-only address CLINT+0xF004: reads are fine, every write returns a bus error.
# Expected: store/AMO access fault (cause 7), mtval = the AMO address. Not checkable against Spike (flat memory).
  .section .text.init,"ax"
  .globl _start
_start:
  la   x29, handler
  csrw mtvec, x29
  li   x20, 0x0200F004
  li   x6, 5
  amoswap.w x15, x6, (x20)             # read ok, write errors -> trap
  li   x5, (1 << 1) | 1                # reached: no trap taken -> fail 1
  j    fail
handler:
  csrr x28, mcause
  li   x29, 7
  bne  x28, x29, bad_cause
  csrr x28, mtval
  bne  x28, x20, bad_tval
  li   x5, 1
  j    fail
bad_cause: li x5, (2 << 1) | 1
  j    fail
bad_tval: li x5, (3 << 1) | 1
fail:
  la   x6, tohost
  sw   x5, 0(x6)
1: j 1b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
