#!/usr/bin/env bash
# Build payload + DTB + OpenSBI (fw_payload) and the simulator RAM image.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$ROOT/tools/gcc/bin:$PATH
B=$ROOT/build
mkdir -p "$B"

# S-mode payload
( cd "$ROOT/sw/payload" &&
  riscv-none-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -O1 \
    -ffreestanding -nostdlib -static -Wall -T link.ld start.S main.c -o payload.elf &&
  riscv-none-elf-objcopy -O binary payload.elf payload.bin )

dtc -I dts -O dtb -o "$B/sim.dtb" "$ROOT/sw/dts/sim.dts"

# The xPack bare-metal linker has no -pie, so OpenSBI is built non-PIC (see patch).
OSBI=$ROOT/tools/opensbi
if grep -q -- '-fPIE -pie' "$OSBI/Makefile"; then
  patch -d "$OSBI" -p1 < "$ROOT/sw/patches/opensbi-no-pie.patch"
fi
rm -rf "$B/opensbi"
make -C "$OSBI" -j"$(nproc)" PLATFORM=generic PLATFORM_RISCV_XLEN=32 \
  PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
  CROSS_COMPILE=riscv-none-elf- OPENSBI_LD_PIE=y FW_PIC=n FW_TEXT_START=0x80000000 \
  O="$B/opensbi" FW_PAYLOAD_PATH="$ROOT/sw/payload/payload.bin" FW_FDT_PATH="$B/sim.dtb" >/dev/null

python3 "$ROOT/sw/bin2hex.py" "$B/fw_payload.hex" "$B/opensbi/platform/generic/firmware/fw_payload.bin"
echo "payload 'done' symbol: $(riscv-none-elf-nm "$ROOT/sw/payload/payload.elf" | awk '$3=="done"{print $1}')"
