#!/bin/bash
# Test musl AArch64 ILP32 in QEMU system emulation on an ILP32 kernel:
#   install musl (build-musl/) into the toolchain sysroot, build /init (ilp32-test qemu/init.c) and the test
#   programs with it, pack an initramfs and boot the kernel. QEMU user mode has no ILP32 support.
#
#   run-musl-test.sh [kernel Image]     (default ilp32-test qemu/out/Image-ilp32-6.12-noa32)
#   KAPPEND=<kernel arguments>          added to the kernel command line, e.g. print-fatal-signals=1
#   NOTIME32=1                          forbid the time32 and stat64 system calls (seccomp, SIGSYS) in
#                                       the whole run: /init is notime32-init.c, the real init /init.real
#   MUSL_BUILD=<musl build directory>   musl to install (default ../build-musl)
#
#   /init                               static musl, runs every program in /tests
#   /tests/musl-test-static             static
#   /tests/musl-test-dynamic            dynamic, /lib/ld-musl-aarch64_ilp32.so.1, also dlopen + TLSDESC
#   /tests/syscall-test-ilp32           ilp32-test libc-free test, built with GCC 14
#   /tests/cxx-test-ilp32               ilp32-test C++ test (libstdc++, exceptions, std::thread)
#   /usr/lib/libtlsmod.so               module for the dlopen test
#   /lib                                libc.so, the dynamic linker, libgcc_s, libstdc++, libatomic
# Output in out/: initramfs.cpio.gz, serial.log
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/test"
cd "$WORK/test"
TOP=$PWD
ILP32_TEST=${ILP32_TEST:-$(realpath "$R/../..")}
IMAGE=${1:-$ILP32_TEST/qemu/out/Image-ilp32-6.12-noa32}
T=aarch64-linux-musl_ilp32
TC=$TOP/../toolchain/out
SYSROOT=$TC/$T/sysroot
CC=$TC/bin/$T-gcc
O=$TOP/out
mkdir -p "$O"

MUSL_BUILD=$(realpath "${MUSL_BUILD:-$TOP/../build-musl}")
echo "==> install musl ($MUSL_BUILD) into $SYSROOT"
# make install only copies files newer than the installed ones; another MUSL_BUILD may have been
# installed later, so make this build the newer one
find "$MUSL_BUILD/lib" "$MUSL_BUILD/obj/include" -type f -exec touch {} +
make -s -C "$MUSL_BUILD" install DESTDIR="$SYSROOT" > /dev/null

echo "==> build"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W"/{lib,usr/lib,tests,dev,proc,tmp}
CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter"
$CC -static $CFLAGS -o "$W/init" "$ILP32_TEST/qemu/init.c"
if [ -n "${NOTIME32:-}" ]; then
	mv "$W/init" "$W/init.real"
	$CC -static -O2 -Wall -o "$W/init" "$ILP32_TEST/qemu/notime32-init.c"
	echo "    NOTIME32: time32 and stat64 system calls forbidden (seccomp)"
	CFLAGS="$CFLAGS -DNOTIME32"
fi
$CC -static $CFLAGS -o "$W/tests/musl-test-static" "$R/musl-test.c" -lpthread
$CC $CFLAGS -o "$W/tests/musl-test-dynamic" "$R/musl-test.c" -ldl -lpthread
$CC -shared -fPIC $CFLAGS -o "$W/usr/lib/libtlsmod.so" "$R/tlsmod.c"
$CC -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -Wl,--build-id=none \
	-o "$W/tests/syscall-test-ilp32" "$ILP32_TEST/tests/syscall-test.c" -lgcc
# syscall-test calls the time32 clock_gettime on purpose (kernel ABI test, no C library): not with NOTIME32
[ -z "${NOTIME32:-}" ] || rm "$W/tests/syscall-test-ilp32"
$TC/bin/$T-g++ -O2 -Wall -pthread -o "$W/tests/cxx-test-ilp32" "$ILP32_TEST/tests/cxx-test.cpp"
# libc.so and the dynamic linker (relative symlink, OpenWrt 300-relative.patch) in /lib, as OpenWrt,
# and the GCC runtime libraries
cp -a "$SYSROOT/lib/libc.so" "$SYSROOT/lib/ld-musl-aarch64_ilp32.so.1" "$W/lib/"
cp -a "$TC/$T"/lib/lib{gcc_s,stdc++,atomic}.so* "$W/lib/"
rm -f "$W"/lib/*.py
$TC/bin/$T-strip --strip-unneeded "$W"/lib/lib{gcc_s,stdc++,atomic}.so.*.* 2>/dev/null || true
for f in "$W/init" "$W"/tests/* "$W/usr/lib/libtlsmod.so" "$W/lib/ld-musl-aarch64_ilp32.so.1"; do
	printf '    %-28s %s %s, interpreter %s\n' "${f#$W}" "$($TC/bin/$T-readelf -h "$f" | sed -n 's/ *Class: *//p')" \
		"$($TC/bin/$T-readelf -h "$f" | sed -n 's/ *Type: *\([A-Z]*\).*/\1/p')" \
		"$($TC/bin/$T-readelf -l "$f" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p')"
done
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -9 > "$O/initramfs.cpio.gz"

echo "==> boot $(basename "$IMAGE")"
timeout "${QEMU_TIMEOUT:-600}" qemu-system-aarch64 -M virt -cpu cortex-a35 -smp 2 -m 512 \
	-nographic -no-reboot -kernel "$IMAGE" -initrd "$O/initramfs.cpio.gz" \
	-append "console=ttyAMA0 rdinit=/init panic=-1 ilp32test.aarch32=0 ${KAPPEND:-}" < /dev/null > "$O/serial.log" 2>&1 || true
sed -n '/^ILP32-TEST/,$p' "$O/serial.log" | sed 's/\x1b\[[0-9;]*m//g; s/\r$//' | grep -av '^\[ *[0-9.]*\]' || true
grep -aq 'ILP32-TEST-RESULT: 0 of' "$O/serial.log" || { grep -a -E 'Kernel panic|Unable to handle|segfault' "$O/serial.log" | head; exit 1; }
