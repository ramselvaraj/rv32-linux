#!/usr/bin/env bash
# Fetch and build everything under tools/ (gitignored): RISC-V GCC, riscv-tests, OpenSBI.
# Needs: curl, git, make, dtc, python3, verilator (for simulation).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/tools
mkdir -p "$T"
GCC_VER=15.2.0-1

if [ ! -x "$T/gcc/bin/riscv-none-elf-gcc" ]; then
  mkdir -p "$T/gcc" "$T/dl"
  curl -L -o "$T/dl/gcc.tar.gz" \
    "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${GCC_VER}/xpack-riscv-none-elf-gcc-${GCC_VER}-linux-x64.tar.gz"
  tar xzf "$T/dl/gcc.tar.gz" -C "$T/gcc" --strip-components=1
  rm -rf "$T/dl"
fi
export PATH=$T/gcc/bin:$PATH

[ -d "$T/riscv-tests" ] || git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/riscv-software-src/riscv-tests.git "$T/riscv-tests"
make -C "$T/riscv-tests/isa" -j"$(nproc)" RISCV_PREFIX=riscv-none-elf- XLEN=32 \
  rv32ui rv32um rv32ua rv32mi rv32si >/dev/null 2>&1 || true

if [ ! -d "$T/opensbi" ]; then
  git clone --depth 1 https://github.com/riscv-software-src/opensbi.git "$T/opensbi"
  patch -d "$T/opensbi" -p1 < "$ROOT/sw/patches/opensbi-no-pie.patch"
fi
echo "tools ready; next: make test && sw/build_opensbi.sh && make test-custom"
