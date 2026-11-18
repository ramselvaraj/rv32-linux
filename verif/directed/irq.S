# Self-checking interrupt tests (DUT only; Spike's CLINT timing differs, so these are not lock-stepped).
# tohost = 1 on success, (test << 1) | 1 on failure of test number `test`.
# Test-bench-only register at CLINT+0xF000 drives MEIP (bit0) and SEIP (bit1).
# x28..x31 belong to the trap handlers; test code uses x5..x15 and x20..x27.
  .equ CLINT,   0x02000000
  .equ MTIMECMP, 0x02004000
  .equ MTIME,    0x0200BFF8
  .equ IRQREG,   0x0200F000

  .macro FAIL n
  li   x5, (\n << 1) | 1
  j    fail
  .endm

  .section .text.init,"ax"
  .globl _start
_start:
  la   x29, m_handler
  csrw mtvec, x29
  li   x29, -1
  csrw pmpaddr0, x29
  li   x29, 0x1f
  csrw pmpcfg0, x29
  csrw mstatus, x0
  csrw mie, x0

# ---- test 1: machine software interrupt (MSI, cause 3)
  la   x20, logbuf
  sw   x0, 0(x20)
  li   x21, 8
  csrw mie, x21
  li   x21, 8
  csrs mstatus, x21                    # MIE
  li   x22, CLINT
  li   x23, 1
  sw   x23, 0(x22)                     # raise msip
  li   x5, 100
1: addi x5, x5, -1
  bnez x5, 1b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t1_fail
  lw   x6, 4(x20)
  li   x7, 0x80000003
  bne  x6, x7, t1_fail
  j    t2
t1_fail: FAIL 1

# ---- test 2: machine timer interrupt (MTI, cause 7)
t2:
  sw   x0, 0(x20)
  li   x21, 0x80
  csrw mie, x21
  li   x22, MTIME
  lw   x23, 0(x22)
  addi x23, x23, 60
  li   x24, MTIMECMP
  li   x25, -1
  sw   x25, 4(x24)
  sw   x23, 0(x24)
  sw   x0, 4(x24)
  li   x21, 8
  csrs mstatus, x21
  li   x5, 400
2: addi x5, x5, -1
  bnez x5, 2b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t2_fail
  lw   x6, 4(x20)
  li   x7, 0x80000007
  bne  x6, x7, t2_fail
  j    t3
t2_fail: FAIL 2

# ---- test 3: machine external interrupt (MEI, cause 11) and test 4: supervisor external (SEI, cause 9)
t3:
  sw   x0, 0(x20)
  li   x21, 0x800
  csrw mie, x21
  li   x22, IRQREG
  li   x23, 1
  sw   x23, 0(x22)
  li   x21, 8
  csrs mstatus, x21
  li   x5, 100
3: addi x5, x5, -1
  bnez x5, 3b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t3_fail
  lw   x6, 4(x20)
  li   x7, 0x8000000b
  bne  x6, x7, t3_fail
  j    t4
t3_fail: FAIL 3
t4:
  sw   x0, 0(x20)
  li   x21, 0x200
  csrw mie, x21
  li   x22, IRQREG
  li   x23, 2
  sw   x23, 0(x22)
  li   x21, 8
  csrs mstatus, x21
  li   x5, 100
4: addi x5, x5, -1
  bnez x5, 4b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t4_fail
  lw   x6, 4(x20)
  li   x7, 0x80000009
  bne  x6, x7, t4_fail
  j    t5
t4_fail: FAIL 4

# ---- test 5: priority MEI > MSI > MTI > SEI, all pending and enabled at once
t5:
  sw   x0, 0(x20)
  li   x21, 0xAAA                      # MEIE | SEIE | MTIE | STIE | MSIE | SSIE
  csrw mie, x21
  li   x22, MTIME
  lw   x23, 0(x22)
  addi x23, x23, 10
  li   x24, MTIMECMP
  li   x25, -1
  sw   x25, 4(x24)
  sw   x23, 0(x24)
  sw   x0, 4(x24)
  li   x22, CLINT
  li   x23, 1
  sw   x23, 0(x22)                     # msip
  la   x22, keep
  li   x23, 2
  sw   x23, 0(x22)                     # MEI handler must leave SEIP pending
  li   x22, IRQREG
  li   x23, 3
  sw   x23, 0(x22)                     # meip + seip
  li   x5, 60
5: addi x5, x5, -1
  bnez x5, 5b                          # let mtime pass the compare
  li   x21, 8
  csrs mstatus, x21                    # now take them in priority order
  li   x5, 200
6: addi x5, x5, -1
  bnez x5, 6b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 4
  bne  x6, x7, t5_fail
  lw   x6, 4(x20)
  li   x7, 0x8000000b
  bne  x6, x7, t5_fail
  lw   x6, 8(x20)
  li   x7, 0x80000003
  bne  x6, x7, t5_fail
  lw   x6, 12(x20)
  li   x7, 0x80000007
  bne  x6, x7, t5_fail
  lw   x6, 16(x20)
  li   x7, 0x80000009
  bne  x6, x7, t5_fail
  la   x22, keep
  sw   x0, 0(x22)
  j    t6
t5_fail: FAIL 5

# ---- test 6: interrupts are masked while mstatus.MIE = 0, and taken when it is set
t6:
  sw   x0, 0(x20)
  li   x21, 8
  csrw mie, x21
  csrc mstatus, x21                    # MIE = 0
  li   x22, CLINT
  li   x23, 1
  sw   x23, 0(x22)
  li   x5, 100
7: addi x5, x5, -1
  bnez x5, 7b
  lw   x6, 0(x20)
  bnez x6, t6_fail                     # nothing may have been taken
  csrs mstatus, x21
  nop
  nop
  nop
  nop
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t6_fail
  j    t7
t6_fail: FAIL 6

# ---- test 7: supervisor software / timer interrupts set by M-mode through mip (SSI cause 1, STI cause 5)
t7:
  sw   x0, 0(x20)
  li   x21, 0x22                       # SSIE | STIE
  csrw mie, x21
  li   x21, 2
  csrs mip, x21                        # SSIP
  li   x21, 8
  csrs mstatus, x21
  li   x5, 50
8: addi x5, x5, -1
  bnez x5, 8b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t7_fail
  lw   x6, 4(x20)
  li   x7, 0x80000001
  bne  x6, x7, t7_fail
  sw   x0, 0(x20)
  li   x21, 0x20
  csrs mip, x21                        # STIP
  li   x21, 8
  csrs mstatus, x21
  li   x5, 50
9: addi x5, x5, -1
  bnez x5, 9b
  csrc mstatus, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t7_fail
  lw   x6, 4(x20)
  li   x7, 0x80000005
  bne  x6, x7, t7_fail
  j    t8
t7_fail: FAIL 7

# ---- test 8: SEI delegated to S-mode (mideleg), taken in S-mode with sie/sstatus.SIE
t8:
  sw   x0, 0(x20)
  csrw mie, x0
  li   x21, 0x200
  csrw mideleg, x21
  la   x21, s_handler
  csrw stvec, x21
  li   x21, 0x200
  csrw sie, x21
  li   x21, 0x1800
  csrc mstatus, x21
  li   x21, 0x800
  csrs mstatus, x21                    # MPP = S
  li   x21, 2
  csrs mstatus, x21                    # SIE (bit 1) so S takes it
  la   x21, s_main
  csrw mepc, x21
  mret
s_main:
  li   x22, IRQREG
  li   x23, 2
  sw   x23, 0(x22)                     # seip
  li   x5, 100
10: addi x5, x5, -1
  bnez x5, 10b
  li   x30, 0x7f0
  ecall                                # back to M
s_done:
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t8_fail
  lw   x6, 4(x20)
  li   x7, 0x80000009
  bne  x6, x7, t8_fail
  csrw mideleg, x0
  j    t9
t8_fail: FAIL 8

# ---- test 9: a pending interrupt whose mie bit is clear must not be taken even with mstatus.MIE = 1
t9:
  sw   x0, 0(x20)
  csrw mie, x0
  li   x22, CLINT
  li   x23, 1
  sw   x23, 0(x22)
  li   x21, 8
  csrs mstatus, x21
  li   x5, 100
11: addi x5, x5, -1
  bnez x5, 11b
  csrc mstatus, x21
  lw   x6, 0(x20)
  bnez x6, t9_fail
  sw   x0, 0(x22)
  j    t10
t9_fail: FAIL 9

# ---- test 10: vectored mtvec (mode 1): interrupt cause 3 enters at base + 4*3
t10:
  sw   x0, 0(x20)
  la   x21, vtab
  ori  x21, x21, 1
  csrw mtvec, x21
  li   x21, 8
  csrw mie, x21
  csrs mstatus, x21
  li   x22, CLINT
  li   x23, 1
  sw   x23, 0(x22)
  li   x5, 100
12: addi x5, x5, -1
  bnez x5, 12b
  csrc mstatus, x21
  la   x21, m_handler
  csrw mtvec, x21
  lw   x6, 0(x20)
  li   x7, 1
  bne  x6, x7, t10_fail
  lw   x6, 4(x20)
  li   x7, 0xC0DE
  bne  x6, x7, t10_fail
  j    pass
t10_fail: FAIL 10

pass:
  li   x5, 1
fail:
  la   x6, tohost
  sw   x5, 0(x6)
1: j 1b

# ---- M-mode trap handler: logs the cause, clears the interrupt source, returns
  .p2align 2
m_handler:
  csrr x30, mcause
  bgez x30, m_exc                      # synchronous: ecall from S for the delegation test
  la   x31, logbuf
  lw   x29, 0(x31)
  slli x28, x29, 2
  addi x28, x28, 4
  add  x28, x31, x28
  sw   x30, 0(x28)
  addi x29, x29, 1
  sw   x29, 0(x31)
  andi x28, x30, 31
  li   x29, 3
  beq  x28, x29, c_msi
  li   x29, 7
  beq  x28, x29, c_mti
  li   x29, 11
  beq  x28, x29, c_mei
  li   x29, 9
  beq  x28, x29, c_ext
  li   x29, 1
  beq  x28, x29, c_ssi
  li   x29, 5
  beq  x28, x29, c_sti
  j    m_ret
c_msi:
  li   x29, CLINT
  sw   x0, 0(x29)
  j    m_ret
c_mti:
  li   x29, MTIMECMP
  li   x28, -1
  sw   x28, 4(x29)
  sw   x28, 0(x29)
  j    m_ret
c_mei:                                 # clear MEIP only; `keep` preserves a pending SEIP (priority test)
  la   x28, keep
  lw   x28, 0(x28)
  li   x29, IRQREG
  sw   x28, 0(x29)
  j    m_ret
c_ext:
  li   x29, IRQREG
  sw   x0, 0(x29)
  j    m_ret
c_ssi:
  li   x29, 2
  csrc mip, x29
  j    m_ret
c_sti:
  li   x29, 0x20
  csrc mip, x29
  j    m_ret
m_ret:
  mret
m_exc:                                 # ecall from S (cause 9): resume at s_done in M-mode
  la   x29, s_done
  csrw mepc, x29
  li   x29, 0x1800
  csrs mstatus, x29
  mret

# ---- vector table for test 10 (16 four-byte slots; slot 3 is the machine software interrupt)
  .p2align 6
vtab:
  j v_bad
  j v_bad
  j v_bad
  j v_msi
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
  j v_bad
v_msi:
  la   x31, logbuf
  li   x29, 1
  sw   x29, 0(x31)
  li   x29, 0xC0DE
  sw   x29, 4(x31)
  li   x29, CLINT
  sw   x0, 0(x29)
  mret
v_bad:
  la   x31, logbuf
  li   x29, 1
  sw   x29, 0(x31)
  li   x29, 0xBAD
  sw   x29, 4(x31)
  li   x29, CLINT
  sw   x0, 0(x29)
  mret

# ---- S-mode handler for the delegated SEI
  .p2align 2
s_handler:
  csrr x30, scause
  la   x31, logbuf
  lw   x29, 0(x31)
  slli x28, x29, 2
  addi x28, x28, 4
  add  x28, x31, x28
  sw   x30, 0(x28)
  addi x29, x29, 1
  sw   x29, 0(x31)
  li   x29, IRQREG
  sw   x0, 0(x29)
  sret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
  .section .data
  .align 4
logbuf: .space 64
keep:   .word 0
