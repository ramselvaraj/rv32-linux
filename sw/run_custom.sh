#!/usr/bin/env bash
# Build and run the repo's own regression tests (sw/tests/*.S) and the OpenSBI boot.
#   sw/run_custom.sh <sim-binary>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIM=$(realpath "$1")
export PATH=$ROOT/tools/gcc/bin:$PATH
R=$ROOT/tools/riscv-tests
mkdir -p "$ROOT/build"
fail=0

for src in "$ROOT"/sw/tests/*.S; do
  n=$(basename "$src" .S)
  riscv-none-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
    -nostdlib -nostartfiles -I"$R/env/p" -I"$R/isa/macros/scalar" -T"$R/env/p/link.ld" \
    "$src" -o "$ROOT/build/$n.elf"
  riscv-none-elf-objcopy -O binary "$ROOT/build/$n.elf" "$ROOT/build/$n.bin"
  python3 "$ROOT/sw/bin2hex.py" "$ROOT/build/$n.hex" "$ROOT/build/$n.bin"
  th=$(riscv-none-elf-nm "$ROOT/build/$n.elf" | awk '$3=="tohost"{print $1}')
  res=$("$SIM" +hex="$ROOT/build/$n.hex" +tohost="$th" +maxcycles=200000 | grep -E 'PASS|FAIL|TIMEOUT' | head -1)
  echo "$n: ${res:-NO RESULT}"
  [[ "$res" == PASS* ]] || fail=1
done

# OpenSBI -> S-mode payload (SBI calls, timer irq, Sv32 paging, page faults)
done_pc=$(riscv-none-elf-nm "$ROOT/sw/payload/payload.elf" | awk '$3=="done"{print $1}')
out=$("$SIM" +hex="$ROOT/build/fw_payload.hex" +halt="$done_pc" +maxcycles=60000000)
echo "$out" | sed -n '/rv32-linux payload/,/PAYLOAD/p'
if echo "$out" | grep -q 'PAYLOAD OK' && echo "$out" | grep -q '^HALT'; then
  echo "opensbi-payload: PASS"
else
  echo "opensbi-payload: FAIL"; fail=1
fi
exit $fail
