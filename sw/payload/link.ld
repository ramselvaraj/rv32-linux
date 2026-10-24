OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80400000;
  .text : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) *(.sdata .sdata.*) }
  . = ALIGN(4096);
  .pt (NOLOAD) : { *(.pt) }
  .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }
  . = ALIGN(16);
  . += 8192;
  _stack_top = .;
}
