#!/bin/bash
# Build libc-test with musl and run it in QEMU system emulation on an ILP32 kernel.
#
#   run-libc-test.sh [kernel Image]     (default test-ilp32 qemu/out/Image-ilp32-6.12.y-noa32)
#   ABI=ilp32                           AArch64 ILP32: the toolchain of ../toolchain, musl installed from
#                                       ../build-musl (default)
#   ABI=lp64                            AArch64 LP64 reference: the same musl tree built with
#                                       aarch64-linux-gnu-gcc into out/musl-lp64, tests built with its musl-gcc
#   LIBC_TEST=<libc-test tree>          (default ~/work/libc-test)
#   MUSL_SRC=<musl tree>                (default ~/work/musl-ilp32, for ABI=lp64)
#   MUSL_BUILD=<musl build directory>   musl to install for ABI=ilp32 (default ../build-musl)
#   out/busybox (build-busybox.sh)      when present: /bin/busybox and /bin/sh, echo, ... for the tests
#                                       that run a shell
#   KAPPEND=<kernel arguments>          added to the kernel command line
#   NOTIME32=1                          forbid the time32 and stat64 system calls (seccomp, SIGSYS) in
#                                       the whole run: /init is notime32-init.c, the real init /init.real
#   TAG=<name>                          output directory out/<name> (default the ABI)
#
# Build: the test binaries and modules only (out/<abi>/libc-test-build), errors in out/<abi>/build-errors.txt.
# Run: /init (lt-init.c) runs each test through runtest.exe -t 30 from /libc-test.
# Output in out/<tag>/: libc-test-serial.log, libc-test-report.txt (FAIL lines and result)
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/test"
cd "$WORK/test"
TOP=$PWD
ABI=${ABI:-ilp32}
ILP32_TEST=${ILP32_TEST:-$(realpath "$R/../..")}
LIBC_TEST=$(realpath "${LIBC_TEST:-$HOME/work/libc-test}")
MUSL_SRC=$(realpath "${MUSL_SRC:-$HOME/work/musl-ilp32}")
IMAGE=${1:-$ILP32_TEST/qemu/out/Image-ilp32-6.12.y-noa32}
O=$TOP/out/${TAG:-$ABI}
BD=$O/libc-test-build
mkdir -p "$O"

case $ABI in
ilp32)
	T=aarch64-linux-musl_ilp32
	TC=$TOP/../toolchain/out
	SYSROOT=$TC/$T/sysroot
	CC=$TC/bin/$T-gcc
	CROSS=$TC/bin/$T-
	MUSL_BUILD=$(realpath "${MUSL_BUILD:-$TOP/../build-musl}")
	echo "==> install musl ($MUSL_BUILD) into $SYSROOT"
	# make install only copies files newer than the installed ones; another MUSL_BUILD may have been
	# installed later, so make this build the newer one
	find "$MUSL_BUILD/lib" "$MUSL_BUILD/obj/include" -type f -exec touch {} +
	make -s -C "$MUSL_BUILD" install DESTDIR="$SYSROOT" > /dev/null
	LIBDIR=$SYSROOT/lib       # libc.so and the dynamic linker, /lib on the target
	TLIBDIR=/lib
	;;
lp64)
	P=$O/musl-lp64
	CROSS=aarch64-linux-gnu-
	echo "==> build musl $(git -C "$MUSL_SRC" log -1 --format=%h) for aarch64 LP64 into $P"
	rm -rf "$O/build-musl" "$P"
	mkdir -p "$O/build-musl"
	(cd "$O/build-musl" && "$MUSL_SRC/configure" --target=aarch64-linux-musl --prefix="$P" --syslibdir="$P/lib" \
		CC=${CROSS}gcc CROSS_COMPILE=$CROSS > configure.log && make -j"${J:-2}" > make.log 2>&1 && make install > /dev/null)
	CC=$P/bin/musl-gcc
	LIBDIR=$P/lib
	TLIBDIR=$P/lib           # the dynamic linker path in the binaries
	;;
*)
	echo "ABI is ilp32 or lp64"; exit 1 ;;
esac

echo "==> build libc-test $(git -C "$LIBC_TEST" log -1 --format='%h %cd' --date=short)"
rm -rf "$BD"
mkdir -p "$BD"
# config.mak.def without the glibc specific part
sed '/glibc specific/,$d' "$LIBC_TEST/config.mak.def" > "$BD/config.mak"
MK=(make -C "$LIBC_TEST" -f Makefile -f "$BD/config.mak" B="$BD" CC="$CC" CROSS_COMPILE="$CROSS")
BINS=$("${MK[@]}" -s debug | sed -n 's/^BINS //p')
LIBS=$("${MK[@]}" -s debug | sed -n 's/^LIBS //p')
"${MK[@]}" -k -j"${J:-2}" $LIBS $BINS > "$O/libc-test-build.log" 2>&1 || true
grep -a "^BUILDERROR" "$O/libc-test-build.log" | sort -u > "$O/build-errors.txt" || true
echo "    $(echo $BINS | wc -w) test binaries, $(ls "$BD"/*/*.exe | wc -l) built, $(wc -l < "$O/build-errors.txt") build errors"

echo "==> initramfs"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W"/{dev,proc,tmp,libc-test} "$W$TLIBDIR"
$CC -static -O2 -Wall -o "$W/init" "$R/lt-init.c"
if [ -n "${NOTIME32:-}" ]; then
	mv "$W/init" "$W/init.real"
	$CC -static -O2 -Wall -o "$W/init" "$ILP32_TEST/qemu/notime32-init.c"
	echo "    NOTIME32: time32 and stat64 system calls forbidden (seccomp)"
fi
cp -a "$LIBDIR/libc.so" "$LIBDIR/ld-musl-"*.so.1 "$W$TLIBDIR/"
[ "$ABI" = ilp32 ] && cp -a "$TC/$T"/lib/libgcc_s.so.1 "$W/lib/"
if [ -f "$TOP/out/busybox" ]; then
	mkdir -p "$W/bin"
	cp "$TOP/out/busybox" "$W/bin/"
	for a in sh echo cat true false env ls test [; do ln -s busybox "$W/bin/$a"; done
	echo "    with busybox"
fi
(cd "$BD" && find . \( -name '*.exe' -o -name '*.so' \) | cpio -pdm --quiet "$W/libc-test")
${CROSS}strip --strip-debug $(find "$W/libc-test" -name '*.exe' -o -name '*.so') 2>/dev/null || true
(cd "$W/libc-test" && find . -name '*.exe' ! -path './common/*' | sed 's|^\./||' | LC_ALL=C sort > list)
# the tests find their modules as src/<dir>/x.so (from the libc-test tree) or by the build path
ln -s . "$W/libc-test/src"
mkdir -p "$W$(dirname "$BD")"
ln -s /libc-test "$W$BD"
echo "    $(wc -l < "$W/libc-test/list") tests"
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) | gzip -6 > "$O/libc-test-initramfs.cpio.gz"

echo "==> boot $(basename "$IMAGE") ($ABI)"
timeout "${QEMU_TIMEOUT:-7200}" qemu-system-aarch64 -M virt -cpu cortex-a35 -smp 2 -m 1024 \
	-nographic -no-reboot -kernel "$IMAGE" -initrd "$O/libc-test-initramfs.cpio.gz" \
	-append "console=ttyAMA0 rdinit=/init panic=-1 ${KAPPEND:-}" < /dev/null > "$O/libc-test-serial.log" 2>&1 || true
sed 's/\x1b\[[0-9;]*m//g; s/\r$//' "$O/libc-test-serial.log" | grep -a '^FAIL\|^LIBC-TEST' > "$O/libc-test-report.txt" || true
cat "$O/libc-test-report.txt"
