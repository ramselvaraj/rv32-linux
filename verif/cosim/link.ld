OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  .ptroot 0x80100000 : { *(.ptroot) }
  .ptl0   0x80101000 : { *(.ptl0) }
  .pgdata 0x80110000 : { *(.pgdata) }
}
