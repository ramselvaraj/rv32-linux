#!/usr/bin/env bash
# Run riscv-tests ISA binaries on the Verilator model.
#   sw/run_isa.sh <sim-binary> [glob-pattern ...]   e.g. 'rv32ui-p-*' 'rv32um-v-*'
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIM=$(realpath "$1"); shift
PATTERNS=("$@")
[ ${#PATTERNS[@]} -eq 0 ] && PATTERNS=('rv32ui-p-*' 'rv32um-p-*' 'rv32ua-p-*' 'rv32mi-p-*' 'rv32si-p-*' \
                                       'rv32ui-v-*' 'rv32um-v-*' 'rv32ua-v-*')
# Not supported by design: ma_data needs hardware misaligned access (OpenSBI emulates it
# in M-mode instead); breakpoint needs the debug trigger module (tselect/tdata*).
XFAIL=' rv32mi-p-breakpoint rv32ui-p-ma_data rv32ui-v-ma_data '
ISA=$ROOT/tools/riscv-tests/isa
BIN=$ROOT/tools/gcc/bin
OUT=$ROOT/build/isa
mkdir -p "$OUT"

run_one() {
  t=$1
  n=$(basename "$t")
  "$BIN/riscv-none-elf-objcopy" -O binary "$t" "$OUT/$n.bin"
  python3 "$ROOT/sw/bin2hex.py" "$OUT/$n.hex" "$OUT/$n.bin"
  th=$("$BIN/riscv-none-elf-nm" "$t" | awk '$3=="tohost"{print $1}')
  res=$(timeout 300 "$SIM" +hex="$OUT/$n.hex" +tohost="$th" +maxcycles=400000 2>&1 | grep -E 'PASS|FAIL|TIMEOUT' | head -1)
  echo "$n: ${res:-NO RESULT}"
}
export -f run_one
export ROOT SIM OUT BIN

files=()
for p in "${PATTERNS[@]}"; do
  for f in "$ISA"/$p; do
    case "$f" in *.dump|*.hex|*.bin) continue;; esac
    [[ "$XFAIL" == *" $(basename "$f") "* ]] && continue
    [ -f "$f" ] && files+=("$f")
  done
done
printf '%s\n' "${files[@]}" | xargs -P 16 -I{} bash -c 'run_one {}' | sort > "$OUT/results.txt"
pass=$(grep -c ': PASS' "$OUT/results.txt")
total=$(wc -l < "$OUT/results.txt")
grep -v ': PASS' "$OUT/results.txt"
echo "== $pass / $total passed (skipped as unsupported:$XFAIL)"
[ "$pass" -eq "$total" ]
