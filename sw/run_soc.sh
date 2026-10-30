#!/usr/bin/env bash
# Boot OpenSBI + the S-mode payload on the FPGA SoC bench (AXI bridges, serial UART).
#   sw/run_soc.sh <sim-binary>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIM=$(realpath "$1")
export PATH=$ROOT/tools/gcc/bin:$PATH
done_pc=$(riscv-none-elf-nm "$ROOT/sw/payload/payload.elf" | awk '$3=="done"{print $1}')
out=$("$SIM" +hex="$ROOT/build/fw_payload.hex" +halt="$done_pc" +maxcycles=${MAXCYC:-100000000})
echo "$out" | sed -n '/rv32-linux payload/,$p' 
if echo "$out" | grep -q 'PAYLOAD OK' && echo "$out" | grep -q 'HALT at'; then
  echo "soc-opensbi-payload: PASS"
else
  echo "soc-opensbi-payload: FAIL"; exit 1
fi
