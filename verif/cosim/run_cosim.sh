#!/usr/bin/env bash
# Lock-step co-sim of every riscv-tests ISA ELF against Spike.
#   verif/cosim/run_cosim.sh <sim-binary> [glob ...]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SIM=$(realpath "$1"); shift
PATTERNS=("$@"); [ ${#PATTERNS[@]} -eq 0 ] && PATTERNS=('rv32ui-p-*' 'rv32um-p-*' 'rv32ua-p-*' 'rv32mi-p-*' 'rv32si-p-*' 'rv32ui-v-*' 'rv32um-v-*' 'rv32ua-v-*')
XFAIL=' rv32mi-p-breakpoint rv32ui-p-ma_data rv32ui-v-ma_data '
OUT=$ROOT/build/cosim; mkdir -p "$OUT"
files=()
for p in "${PATTERNS[@]}"; do for f in "$ROOT"/tools/riscv-tests/isa/$p; do
  case "$f" in *.dump|*.hex|*.bin) continue;; esac
  [[ "$XFAIL" == *" $(basename "$f") "* ]] && continue; [ -f "$f" ] && files+=("$f"); done; done
printf '%s\n' "${files[@]}" | xargs -P 16 -I{} python3 "$ROOT/verif/cosim/cosim.py" "$SIM" {} | sort > "$OUT/results.txt"
m=$(grep -c ': MATCH' "$OUT/results.txt"); t=$(wc -l < "$OUT/results.txt")
grep -v ': MATCH' "$OUT/results.txt"
echo "== cosim vs Spike: $m / $t tests identical"
[ "$m" -eq "$t" ]
