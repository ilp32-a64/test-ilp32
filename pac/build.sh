#!/bin/bash
# Build the pointer authentication (PAC), BTI, SVE and SME test programs and an initramfs: the one of
# qemu/make-initramfs.sh with these programs added in /tests (and /pac-data for btitrap-check).
# Toolchains: the ILP32 GCC 14.3 + glibc 2.41 of glibc/ ($GLIBC_WORK/toolchain/out, default
# ~/work/ilp32-glibc), clang 22 with the ILP32 patches of ilp32-a64/llvm-ilp32 on top of it (CLANG,
# default ~/work/build/llvm22-ilp32/bin/clang; without it the clang programs are left out), the LP64
# aarch64-linux-gnu-gcc-14 (LP64_CC). All programs are static.
#   pac-clang-ilp32        ILP32, clang -mbranch-protection=pac-ret (GCC has no return address signing
#                          for ILP32)
#   pac-gcc-ilp32          ILP32, GCC, no return address signing (the kernel side only)
#   pac-cxx-*              C++ exceptions through pac-ret frames (clang + the libgcc unwinder) and controls
#   pac-gcc-lp64           LP64, GCC -mbranch-protection=pac-ret
#   sve-gcc-{ilp32,lp64}   SVE (and SME where the kernel has it)
#   *bti-nolibc-*          programs without the C library, with a GNU property note (BTI) or without
#   btitrap-check-ilp32    runs /pac-data/btitrap-nolibc-{ilp32,lp64}: an indirect call to a function
#                          without a landing pad, SIGILL expected on a CPU with BTI
# Output: pac/out/tests/, pac/out/initramfs-pac.cpio.gz (run it with pac/run.sh)
set -euo pipefail
cd "$(dirname "$0")"
TC=${GLIBC_WORK:-$HOME/work/ilp32-glibc}/toolchain/out
T=aarch64-linux-gnu_ilp32
GCC=$TC/bin/$T-gcc
GXX=$TC/bin/$T-g++
CLANG=${CLANG:-$HOME/work/build/llvm22-ilp32/bin/clang}
CL=(--target=$T --gcc-toolchain="$TC" --sysroot="$TC/$T/sysroot")
LP64=${LP64_CC:-aarch64-linux-gnu-gcc-14}
PAC=-mbranch-protection=pac-ret
INITRAMFS=../qemu/out/initramfs.cpio.gz
[ -x "$GCC" ] || { echo "no ILP32 toolchain $GCC: build it with glibc/rebuild-all.sh"; exit 1; }
[ -f "$INITRAMFS" ] || { echo "no $INITRAMFS: run qemu/make-initramfs.sh first"; exit 1; }
rm -rf out/tests out/pac-data
mkdir -p out/tests out/pac-data

echo "==> $("$GCC" --version | head -1); $($LP64 --version | head -1)"
if [ -x "$CLANG" ]; then
	echo "==> $("$CLANG" --version | head -1)"
	"$CLANG" "${CL[@]}" -O2 -Wall $PAC -static pac-test.c -o out/tests/pac-clang-ilp32
	"${CLANG}++" "${CL[@]}" -O2 -Wall $PAC -static pac-cxx.cpp -o out/tests/pac-cxx-clang-ilp32
	"${CLANG}++" "${CL[@]}" -O2 -Wall -static pac-cxx.cpp -o out/tests/pac-cxx-clang-nopac-ilp32
else
	echo "==> no clang ($CLANG): no pac-clang-ilp32, pac-cxx-clang-*"
fi
"$GCC" -O2 -Wall -static pac-test.c -o out/tests/pac-gcc-ilp32
"$GXX" -O2 -Wall -static pac-cxx.cpp -o out/tests/pac-cxx-gcc-ilp32
$LP64 -O2 -Wall $PAC -static pac-test.c -o out/tests/pac-gcc-lp64
SVE=-march=armv9-a+sve2+sme
"$GCC" -O2 -Wall -static $SVE sve-test.c -o out/tests/sve-gcc-ilp32
$LP64 -O2 -Wall -static $SVE sve-test.c -o out/tests/sve-gcc-lp64

NOLIBC=(-O2 -static -nostdlib -ffreestanding -fno-stack-protector -Wl,--build-id=none)
"$GCC" "${NOLIBC[@]}" -mbranch-protection=bti bti-nolibc.c -o out/tests/bti-nolibc-ilp32
"$GCC" "${NOLIBC[@]}" bti-nolibc.c -o out/tests/nobti-nolibc-ilp32
$LP64 "${NOLIBC[@]}" -mbranch-protection=bti bti-nolibc.c -o out/tests/bti-nolibc-lp64
"$GCC" "${NOLIBC[@]}" -mbranch-protection=bti btitrap-nolibc.c -o out/pac-data/btitrap-nolibc-ilp32
$LP64 "${NOLIBC[@]}" -mbranch-protection=bti btitrap-nolibc.c -o out/pac-data/btitrap-nolibc-lp64
"$GCC" -O2 -Wall -static btitrap-check.c -o out/tests/btitrap-check-ilp32

for f in out/tests/* out/pac-data/*; do
	n=$(aarch64-linux-gnu-objdump -d "$f" | grep -cE 'paciasp|hint\s+#0x19|hint\s+#25' || true)
	p=$(aarch64-linux-gnu-readelf -lW "$f" | grep -c GNU_PROPERTY || true)
	echo "$(basename "$f"): $(file -b "$f" | cut -d, -f1-2), paciasp: $n, GNU_PROPERTY: $p"
done

# the qemu/ initramfs (init, ILP32 runtime, its tests) with these programs appended
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp -r out/tests out/pac-data "$W/"
(cd "$W" && find tests pac-data | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -9 > out/pac.cpio.gz
cat "$INITRAMFS" out/pac.cpio.gz > out/initramfs-pac.cpio.gz
echo "==> pac/out/initramfs-pac.cpio.gz"
