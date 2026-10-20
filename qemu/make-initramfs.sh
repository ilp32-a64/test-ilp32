#!/bin/bash
# Initramfs for the QEMU ILP32 test: /init (qemu/init.c, static ILP32), the ILP32 runtime (glibc, libgcc_s,
# libstdc++ in /libilp32, dynamic linker /lib/ld-linux-aarch64_ilp32.so.1) and the test programs in /tests
# (tests/out: ILP32 programs and the static AArch32 one).
# Output: qemu/out/initramfs.cpio.gz
set -e
cd "$(dirname "$0")"
Q=$PWD
TC=$Q/../toolchain/out
T=aarch64-linux-gnu_ilp32
SYSROOT=$TC/$T/sysroot
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W"/{libilp32,lib,tests,dev,proc,tmp} "$Q/out"
$TC/bin/$T-gcc -static -O2 -Wall -o "$W/init" init.c
# shared objects only (no .a, .o or linker scripts), symlinks kept
for d in "$SYSROOT/libilp32" "$SYSROOT/usr/libilp32" "$TC/$T/libilp32"; do
	find "$d" -maxdepth 1 \( -name '*.so.*' -o -name 'ld-*.so' -o -name 'lib*-2.30.so' \) \
		\( -type f -o -type l \) ! -name '*.py' -exec cp -a {} "$W/libilp32/" \;
done
$TC/bin/$T-strip --strip-unneeded "$W"/libilp32/*.so* 2>/dev/null || true
ln -s ../libilp32/ld-2.30.so "$W/lib/ld-linux-aarch64_ilp32.so.1"
cp "$Q"/../tests/out/* "$W/tests/"
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -9 > "$Q/out/initramfs.cpio.gz"
echo "==> $Q/out/initramfs.cpio.gz ($(stat -c %s "$Q/out/initramfs.cpio.gz") bytes): $(ls "$W/libilp32" | wc -l) runtime files, tests: $(ls "$W/tests" | tr '\n' ' ')"
