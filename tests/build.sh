#!/bin/bash
# Build the test programs into tests/out/.
#   syscall-test-ilp32  ILP32, static, no C library: raw system calls, auxv, vDSO ELF header and symbols
#   glibc-test-ilp32    ILP32 glibc: types, threads, vDSO clock_gettime vs system call, signals, fork, stat, dlopen
#   cxx-test-ilp32      ILP32 libstdc++
#   aarch32-test        AArch32 (armhf), static glibc: the AArch32 side of a kernel with AARCH32_EL0=y
#                       (needs arm-linux-gnueabihf-gcc, Ubuntu package gcc-arm-linux-gnueabihf)
# ILP32 toolchain: GCC 14.3 and glibc 2.41 (64-bit time_t) built by glibc/rebuild-all.sh in
# $GLIBC_WORK/toolchain/out (default ~/work/ilp32-glibc); ILP32_PREFIX overrides the compiler prefix.
set -e
cd "$(dirname "$0")"
P=${ILP32_PREFIX:-${GLIBC_WORK:-$HOME/work/ilp32-glibc}/toolchain/out/bin/aarch64-linux-gnu_ilp32-}
A32=${AARCH32_CC:-arm-linux-gnueabihf-gcc}
[ -x "${P}gcc" ] || { echo "no ILP32 toolchain ${P}gcc: build it with glibc/rebuild-all.sh"; exit 1; }
mkdir -p out
${P}gcc -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -Wl,--build-id=none \
	-o out/syscall-test-ilp32 syscall-test.c -lgcc
${P}gcc -O2 -Wall -pthread -o out/glibc-test-ilp32 glibc-test.c -ldl
${P}g++ -O2 -Wall -pthread -o out/cxx-test-ilp32 cxx-test.cpp
$A32 -static -O2 -Wall -o out/aarch32-test aarch32-test.c
echo "==> $(${P}gcc --version | head -1)"
for f in out/*; do
	printf '%-24s %s %s, interpreter %s\n' $f "$(readelf -h $f | sed -n 's/ *Class: *//p')" \
		"$(readelf -h $f | sed -n 's/ *Machine: *//p')" "$(readelf -l $f | sed -n 's/.*interpreter: \(.*\)]/\1/p')"
done
