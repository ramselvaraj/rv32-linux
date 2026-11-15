#!/usr/bin/env bash
# Build the Linux userspace + kernel (Buildroot, musl, BusyBox initramfs) into build/linux.
# Fills the repo path into the defconfig, so the checkout can live anywhere.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BR=${BUILDROOT:-$ROOT/tools/buildroot}
[ -d "$BR" ] || git clone --depth 1 https://gitlab.com/buildroot.org/buildroot.git "$BR"
mkdir -p "$ROOT/build"
sed "s#@REPO@#$ROOT#g" "$ROOT/sw/linux/rv32core_defconfig" > "$ROOT/build/rv32core_defconfig"
make -C "$BR" O="$ROOT/build/linux" BR2_DEFCONFIG="$ROOT/build/rv32core_defconfig" defconfig
make -C "$ROOT/build/linux"
