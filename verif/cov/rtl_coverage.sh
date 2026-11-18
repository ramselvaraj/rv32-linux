#!/usr/bin/env bash
# Verilator line + toggle coverage of the core RTL over the whole corpus (riscv-tests + random programs).
#   verif/cov/rtl_coverage.sh [max-random-per-profile]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAXR=${1:-100000}
D=$ROOT/build/cov; rm -rf "$D"; mkdir -p "$D/dat"
CORE="rtl/core/rv_pkg.sv rtl/core/rv_alu.sv rtl/core/rv_regfile.sv rtl/core/rv_decode.sv rtl/core/rv_muldiv.sv rtl/core/rv_tlb.sv rtl/core/rv_ptw.sv rtl/core/rv_dmux.sv rtl/core/rv_fetch.sv rtl/core/rv_csr.sv rtl/core/rv_core.sv"
cd "$ROOT"
verilator --binary --timing --coverage-line --coverage-toggle -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-WIDTH \
  --top-module tb_top -O1 --Mdir "$D/obj" -o Vtb_top $CORE tb/sim_ram.sv tb/sim_periph.sv tb/tb_top.sv >"$D/build.log" 2>&1 || { tail "$D/build.log"; exit 1; }
SIM=$D/obj/Vtb_top
NM=$ROOT/tools/gcc/bin/riscv-none-elf-nm; OBJCOPY=$ROOT/tools/gcc/bin/riscv-none-elf-objcopy
run_one() {
  e=$1; n=$(basename "$e")_$(echo "$e" | md5sum | cut -c1-6)
  $OBJCOPY -O binary "$e" "$D/$n.bin"; python3 "$ROOT/sw/bin2hex.py" "$D/$n.hex" "$D/$n.bin"
  th=$($NM "$e" | awk '$3=="tohost"{print $1}')
  timeout 300 "$SIM" +hex="$D/$n.hex" +tohost="$th" +maxcycles=3000000 +verilator+coverage+file+"$D/dat/$n.dat" >/dev/null 2>&1
  rm -f "$D/$n.bin" "$D/$n.hex"
}
export -f run_one; export D ROOT SIM NM OBJCOPY
{
  for f in "$ROOT"/tools/riscv-tests/isa/rv32[um][iam]-[pv]-* "$ROOT"/tools/riscv-tests/isa/rv32s[i]-p-* "$ROOT"/tools/riscv-tests/isa/rv32ua-v-*; do
    case "$f" in *.dump|*.hex|*.bin) continue;; esac
    case "$(basename $f)" in rv32mi-p-breakpoint|rv32ui-p-ma_data|rv32ui-v-ma_data) continue;; esac
    [ -f "$f" ] && echo "$f"; done
  for p in "$ROOT"/build/random/*/; do ls "$p"r*.elf 2>/dev/null | head -n "$MAXR"; done
  ls "$ROOT"/build/directed/*.elf 2>/dev/null
} | xargs -P 20 -I{} bash -c 'run_one {}'
verilator_coverage --write "$D/merged.dat" "$D"/dat/*.dat >/dev/null 2>&1
verilator_coverage --annotate "$D/annot" --annotate-min 1 "$D/merged.dat" 2>&1 | tail -3 | tee "$D/summary.txt"
echo "programs: $(ls "$D"/dat | wc -l)"
