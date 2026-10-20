#!/bin/bash
# Build the test programs into tests/out/.
#   syscall-test-ilp32  ILP32, static, no C library: raw system calls, auxv, vDSO ELF header and symbols
#   glibc-test-ilp32    ILP32 glibc: types, threads, vDSO clock_gettime vs system call, signals, fork, stat, dlopen
#   cxx-test-ilp32      ILP32 libstdc++
#   aarch32-test        AArch32 (armhf), static glibc: the AArch32 side of a kernel with AARCH32_EL0=y
#                       (needs arm-linux-gnueabihf-gcc, Ubuntu package gcc-arm-linux-gnueabihf)
set -e
cd "$(dirname "$0")"
P=${ILP32_PREFIX:-$PWD/../toolchain/out/bin/aarch64-linux-gnu_ilp32-}
A32=${AARCH32_CC:-arm-linux-gnueabihf-gcc}
mkdir -p out
${P}gcc -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -Wl,--build-id=none \
	-o out/syscall-test-ilp32 syscall-test.c
${P}gcc -O2 -Wall -pthread -o out/glibc-test-ilp32 glibc-test.c -ldl
${P}g++ -O2 -Wall -pthread -o out/cxx-test-ilp32 cxx-test.cpp
$A32 -static -O2 -Wall -o out/aarch32-test aarch32-test.c
for f in out/*; do
	printf '%-24s %s %s, interpreter %s\n' $f "$(readelf -h $f | sed -n 's/ *Class: *//p')" \
		"$(readelf -h $f | sed -n 's/ *Machine: *//p')" "$(readelf -l $f | sed -n 's/.*interpreter: \(.*\)]/\1/p')"
done
