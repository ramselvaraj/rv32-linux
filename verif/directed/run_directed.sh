#!/usr/bin/env bash
# Build and run the directed (self-checking, DUT-only) tests.
#   verif/directed/run_directed.sh <sim-binary>
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); SIM=$(realpath "$1")
GCC=$ROOT/tools/gcc/bin/riscv-none-elf-gcc; NM=$ROOT/tools/gcc/bin/riscv-none-elf-nm; OC=$ROOT/tools/gcc/bin/riscv-none-elf-objcopy
OUT=$ROOT/build/directed; mkdir -p "$OUT"; rc=0
for s in "$ROOT"/verif/directed/*.S; do
  n=$(basename "$s" .S)
  $GCC -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -T "$ROOT/verif/cosim/link.ld" -o "$OUT/$n.elf" "$s" || { echo "$n: BUILD-FAIL"; rc=1; continue; }
  $OC -O binary "$OUT/$n.elf" "$OUT/$n.bin"; python3 "$ROOT/sw/bin2hex.py" "$OUT/$n.hex" "$OUT/$n.bin"
  th=$($NM "$OUT/$n.elf" | awk '$3=="tohost"{print $1}')
  res=$("$SIM" +hex="$OUT/$n.hex" +tohost="$th" +maxcycles=2000000 2>&1 | grep -E 'PASS|FAIL|TIMEOUT' | head -1)
  echo "$n: ${res:-NO RESULT}"; [[ "$res" == PASS* ]] || rc=1
done
exit $rc
