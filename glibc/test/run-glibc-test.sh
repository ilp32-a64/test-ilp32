#!/bin/bash
# Test the AArch64 ILP32 glibc 2.41 (build-glibc.sh, installed in the toolchain sysroot) in QEMU system
# emulation on an ILP32 kernel. QEMU user mode has no ILP32 support.
#
#   run-glibc-test.sh [kernel Image]     (default test-ilp32 qemu/out/Image-ilp32-6.12-noa32)
#   KAPPEND=<kernel arguments>           added to the kernel command line, e.g. print-fatal-signals=1
#   NOTIME32=1                          forbid the time32 and stat64 system calls (seccomp, SIGSYS) in
#                                       the whole run: /init is notime32-init.c, the real init /init.real
#
#   /init                                static glibc, runs every program in /tests (test-ilp32 qemu/init.c)
#   /tests/glibc-test-ilp32              test-ilp32 tests/glibc-test.c, dynamic
#   /tests/syscall-test-ilp32            test-ilp32 tests/syscall-test.c, no C library
#   /tests/libc-test-{static,dynamic}    test-ilp32 musl/test/musl-test.c (generic and Linux APIs:
#                                        64-bit arguments, stat/statx, locks, time64, signals, threads,
#                                        TLS, IPC, fenv, dlopen with TLS)
#   /tests/cxx-test-ilp32                test-ilp32 tests/cxx-test.cpp (libstdc++, exceptions, std::thread)
#   /usr/lib/libtlsmod.so                module for the dlopen test
#   /libilp32                            glibc, libgcc_s, libstdc++ (stage 2 toolchain)
# Output in out/: initramfs.cpio.gz, serial.log
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${GLIBC_WORK:-$HOME/work/ilp32-glibc}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/test"
cd "$WORK/test"
TOP=$PWD
ILP32_TEST=${ILP32_TEST:-$(realpath "$R/../..")}
MUSL_TEST=${MUSL_TEST:-$ILP32_TEST/musl/test}
IMAGE=${1:-$ILP32_TEST/qemu/out/Image-ilp32-6.12-noa32}
T=aarch64-linux-gnu_ilp32
TC=$TOP/../toolchain/out
SYSROOT=$TC/$T/sysroot
CC=$TC/bin/$T-gcc
O=$TOP/out
mkdir -p "$O"

echo "==> build"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W"/{lib,libilp32,usr/lib,tests,dev,proc,tmp}
CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter"
DYN=""
$CC -static $CFLAGS -o "$W/init" "$ILP32_TEST/qemu/init.c"
if [ -n "${NOTIME32:-}" ]; then
	mv "$W/init" "$W/init.real"
	$CC -static -O2 -Wall -o "$W/init" "$ILP32_TEST/qemu/notime32-init.c"
	echo "    NOTIME32: time32 and stat64 system calls forbidden (seccomp)"
	CFLAGS="$CFLAGS -DNOTIME32"
fi
GLIBC_TEST=$ILP32_TEST/tests/glibc-test.c
if [ -n "${NOTIME32:-}" ]; then
	# glibc-test compares the vDSO with the time32 clock_gettime system call (into a 64-bit timespec):
	# use clock_gettime64 in a copy
	sed "s/SYS_clock_gettime,/SYS_clock_gettime64,/" "$GLIBC_TEST" > "$W/glibc-test-notime32.c"
	GLIBC_TEST=$W/glibc-test-notime32.c
fi
$CC $DYN -O2 -Wall -pthread -o "$W/tests/glibc-test-ilp32" "$GLIBC_TEST" -ldl
$CC -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -Wl,--build-id=none \
	-o "$W/tests/syscall-test-ilp32" "$ILP32_TEST/tests/syscall-test.c" -lgcc
# syscall-test calls the time32 clock_gettime on purpose (kernel ABI test, no C library): not with NOTIME32
[ -z "${NOTIME32:-}" ] || rm "$W/tests/syscall-test-ilp32"
$CC -static $CFLAGS -o "$W/tests/libc-test-static" "$MUSL_TEST/musl-test.c" -lpthread -lm
$CC $DYN $CFLAGS -o "$W/tests/libc-test-dynamic" "$MUSL_TEST/musl-test.c" -ldl -lpthread -lm
$CC -shared -fPIC $DYN $CFLAGS -o "$W/usr/lib/libtlsmod.so" "$MUSL_TEST/tlsmod.c"
$TC/bin/$T-g++ -O2 -Wall -pthread -o "$W/tests/cxx-test-ilp32" "$ILP32_TEST/tests/cxx-test.cpp"
# runtime: the dynamic linker in /lib, the libraries in /libilp32
cp -a "$SYSROOT"/lib/ld-linux-aarch64_ilp32.so.1 "$W/lib/"
for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1; do
	[ -e "$SYSROOT/libilp32/$f" ] && cp -aL "$SYSROOT/libilp32/$f" "$W/libilp32/"
done
cp -aL "$TC/$T"/libilp32/libgcc_s.so.1 "$TC/$T"/libilp32/libstdc++.so.6 "$W/libilp32/"
for f in "$W/init" "$W"/tests/* "$W/usr/lib/libtlsmod.so" "$W/lib/ld-linux-aarch64_ilp32.so.1" "$W/libilp32/libc.so.6"; do
	printf '    %-32s %s %s, interpreter %s\n' "${f#$W}" "$($TC/bin/$T-readelf -h "$f" | sed -n 's/ *Class: *//p')" \
		"$($TC/bin/$T-readelf -h "$f" | sed -n 's/ *Type: *\([A-Z]*\).*/\1/p')" \
		"$($TC/bin/$T-readelf -l "$f" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p')"
done
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -9 > "$O/initramfs.cpio.gz"

echo "==> boot $(basename "$IMAGE")"
timeout "${QEMU_TIMEOUT:-600}" qemu-system-aarch64 -M virt -cpu cortex-a35 -smp 2 -m 512 \
	-nographic -no-reboot -kernel "$IMAGE" -initrd "$O/initramfs.cpio.gz" \
	-append "console=ttyAMA0 rdinit=/init panic=-1 ilp32test.aarch32=0 ${KAPPEND:-}" < /dev/null > "$O/serial.log" 2>&1 || true
sed -n '/^ILP32-TEST/,$p' "$O/serial.log" | sed 's/\x1b\[[0-9;]*m//g; s/\r$//' | grep -av '^\[ *[0-9.]*\]' || true
grep -aq 'ILP32-TEST-RESULT: 0 of' "$O/serial.log" || { grep -a -E 'Kernel panic|Unable to handle|segfault|fatal signal' "$O/serial.log" | head; exit 1; }
