#!/bin/bash
# Initramfs for the QEMU ILP32 test: /init (qemu/init.c, static ILP32), the ILP32 runtime of glibc 2.41
# (dynamic linker /lib/ld-linux-aarch64_ilp32.so.1; glibc, libgcc_s and libstdc++ in /libilp32) and the
# test programs in /tests (tests/out: ILP32 programs and the static AArch32 one).
# Toolchain: as tests/build.sh, $GLIBC_WORK/toolchain/out (default ~/work/ilp32-glibc).
# Output: qemu/out/initramfs.cpio.gz
set -e
cd "$(dirname "$0")"
Q=$PWD
TC=${GLIBC_WORK:-$HOME/work/ilp32-glibc}/toolchain/out
T=aarch64-linux-gnu_ilp32
SYSROOT=$TC/$T/sysroot
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W"/{libilp32,lib,tests,dev,proc,tmp} "$Q/out"
$TC/bin/$T-gcc -static -O2 -Wall -o "$W/init" init.c
cp -aL "$SYSROOT/lib/ld-linux-aarch64_ilp32.so.1" "$W/lib/"
for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1; do
	cp -aL "$SYSROOT/libilp32/$f" "$W/libilp32/"
done
cp -aL "$TC/$T/libilp32/libgcc_s.so.1" "$TC/$T/libilp32/libstdc++.so.6" "$W/libilp32/"
$TC/bin/$T-strip --strip-unneeded "$W"/libilp32/*.so* 2>/dev/null || true
cp "$Q"/../tests/out/* "$W/tests/"
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -9 > "$Q/out/initramfs.cpio.gz"
echo "==> $Q/out/initramfs.cpio.gz ($(stat -c %s "$Q/out/initramfs.cpio.gz") bytes): glibc 2.41 runtime" \
	"$(ls "$W/libilp32" | tr '\n' ' '), tests: $(ls "$W/tests" | tr '\n' ' ')"
