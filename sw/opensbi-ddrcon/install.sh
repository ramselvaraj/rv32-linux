#!/usr/bin/env bash
# Idempotently add the DDR-mailbox console driver to the OpenSBI tree (tools/opensbi).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); O=$ROOT/tools/opensbi; S=$O/lib/utils/serial
cp "$ROOT/sw/opensbi-ddrcon/fdt_serial_ddrcon.c" "$S/"
grep -q FDT_SERIAL_DDRCON "$S/Kconfig" || sed -i '/^config FDT_SERIAL_XILINX_UARTLITE/i config FDT_SERIAL_DDRCON\n\tbool "rv32-linux DDR mailbox console"\n\tdefault n\n' "$S/Kconfig"
grep -q FDT_SERIAL_DDRCON "$S/objects.mk" || printf '\ncarray-fdt_serial_drivers-$(CONFIG_FDT_SERIAL_DDRCON) += fdt_serial_ddrcon\nlibsbiutils-objs-$(CONFIG_FDT_SERIAL_DDRCON) += serial/fdt_serial_ddrcon.o\n' >> "$S/objects.mk"
grep -q FDT_SERIAL_DDRCON "$O/platform/generic/configs/defconfig" || echo 'CONFIG_FDT_SERIAL_DDRCON=y' >> "$O/platform/generic/configs/defconfig"
