#!/usr/bin/env bash
# OpenSBI fw_payload = kernel Image (initramfs embedded) + board DTB -> build/fw_linux.bin
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$ROOT/tools/gcc/bin:$PATH
B=$ROOT/build
dtc -I dts -O dtb -o "$B/board.dtb" "$ROOT/sw/dts/board.dts"
rm -rf "$B/opensbi_linux"
make -C "$ROOT/tools/opensbi" -j"$(nproc)" PLATFORM=generic PLATFORM_RISCV_XLEN=32 \
  PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
  CROSS_COMPILE=riscv-none-elf- OPENSBI_LD_PIE=y FW_PIC=n FW_TEXT_START=0x80000000 \
  FW_PAYLOAD_OFFSET=0x400000 O="$B/opensbi_linux" \
  FW_PAYLOAD_PATH="$B/linux/images/Image" FW_FDT_PATH="$B/board.dtb" >/dev/null
cp "$B/opensbi_linux/platform/generic/firmware/fw_payload.bin" "$B/fw_linux.bin"
ls -l "$B/fw_linux.bin"
