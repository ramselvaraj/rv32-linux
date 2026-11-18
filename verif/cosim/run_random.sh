#!/usr/bin/env bash
# Random-program lock-step regression.
#   verif/cosim/run_random.sh <sim-binary> <first-seed> <count> [n-instrs] [profile]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SIM=$(realpath "$1"); S0=$2; CNT=$3; N=${4:-400}; PROF=${5:-mix}
GCC=$ROOT/tools/gcc/bin/riscv-none-elf-gcc
OUT=$ROOT/build/random/$PROF; mkdir -p "$OUT"
one() {
  s=$1; f=$OUT/r$s
  python3 "$ROOT/verif/cosim/gen_random.py" "$s" "$f.S" --n "$N" --profile "$PROF" || { echo "r$s: GEN-FAIL"; return; }
  "$GCC" -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -T "$ROOT/verif/cosim/link.ld" -o "$f.elf" "$f.S" 2>"$f.err" || { echo "r$s: BUILD-FAIL"; return; }
  python3 "$ROOT/verif/cosim/cosim.py" "$SIM" "$f.elf"
}
export -f one; export ROOT SIM N PROF GCC OUT
seq "$S0" $((S0+CNT-1)) | xargs -P 20 -I{} bash -c 'one {}' | sed 's/^r/r/' | sort -V > "$OUT/results.txt"
m=$(grep -c ': MATCH' "$OUT/results.txt")
grep -v ': MATCH' "$OUT/results.txt" | head -20
echo "== random[$PROF] x$N instrs: $m / $CNT programs identical to Spike"
[ "$m" -eq "$CNT" ]
