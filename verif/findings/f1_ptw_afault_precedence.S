# F1: access fault vs page fault precedence for a leaf PTE whose PPN is beyond 32-bit PA.
# Leaf at VA 0x11000000 (4 MiB superpage): V|X|A, no R, PPN[1] bit set (PA >= 2^32).
# S-mode LOAD: the PTE does not permit reads -> Sv32 says raise a LOAD PAGE FAULT (13) before any PA validity
# check. This core's walker raises LOAD ACCESS FAULT (5) as soon as it sees the high PPN bits.
  .section .text.init,"ax"
  .globl _start
_start:
  la   x29, handler
  csrw mtvec, x29
  li   x29, -1
  csrw pmpaddr0, x29
  li   x29, 0x1f
  csrw pmpcfg0, x29
  li   x28, 0x80100000                 # root table (see link.ld)
  li   x29, 0x40000049                 # PPN[1] high bit, V|X|A (R=0, W=0)
  li   x27, 0x11000000
  srli x27, x27, 22
  slli x27, x27, 2
  add  x27, x27, x28
  sw   x29, 0(x27)
  li   x29, 0x200000cf                 # identity 4 MiB superpage for the code: V|R|W|X|A|D, U=0
  li   x27, 0x80100800                 # root[0x200]
  sw   x29, 0(x27)
  li   x29, 0x80000000 | 0x80100
  csrw satp, x29
  sfence.vma x0, x0
  la   x29, s_code
  csrw mepc, x29
  li   x28, 0x1800
  csrc mstatus, x28
  li   x28, 0x800
  csrs mstatus, x28                    # MPP = S
  mret
s_code:
  li   x29, 0x11000000
  lw   x5, 0(x29)                      # expected: cause 13 (page fault); this core: cause 5 (access fault)
  li   x30, 0x7ff
  ecall
  la   x1, tohost                      # back in M mode after the ecall handler: signal pass to the harness
  li   x2, 1
  sw   x2, 0(x1)
1: j 1b
handler:
  csrr x28, mcause
  csrr x29, mtval
  csrr x28, mstatus
  csrr x29, mepc
  addi x29, x29, 4
  csrw mepc, x29
  li   x28, 0x7ff
  bne  x30, x28, 1f
  li   x28, 0x1800
  csrs mstatus, x28
  li   x30, 0
1: mret
  .p2align 2
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
