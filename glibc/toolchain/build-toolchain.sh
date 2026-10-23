#!/bin/bash
# AArch64 ILP32 glibc cross toolchain: autoconf 2.72 (to regenerate glibc's configure), binutils 2.44 and
# GCC 14.3.0 (the GNU releases; GCC with the ILP32 fixes in patches/gcc-14.3.0/), and the kernel headers
# of an ILP32 kernel tree.
#   stage 1 (default): GCC C only, no C library; glibc (../build-glibc.sh) is built with it
#   stage 2 (STAGE=2, after glibc is installed in the sysroot): GCC C and C++, libgcc_s, libstdc++
#
#   build-toolchain.sh [kernel source tree]     (default ~/work/wt/ilp32-6.12.y)
#   STAGE=2 build-toolchain.sh
#
#   target          aarch64-linux-gnu_ilp32 (GCC default -mabi=ilp32)
#   libraries       /libilp32 and /usr/libilp32, the GCC multilib directory for ILP32,
#                   dynamic linker /lib/ld-linux-aarch64_ilp32.so.1
#   prefix          out/ (tools prefixed with the target), sysroot out/aarch64-linux-gnu_ilp32/sysroot
#   autoconf        out-host/bin/autoconf
# Each step leaves a stamp file (build/.<step>) and is skipped when re-run; delete it to redo a step.
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${GLIBC_WORK:-$HOME/work/ilp32-glibc}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/toolchain"
cd "$WORK/toolchain"
TOP=$PWD
KSRC=$(realpath "${1:-$HOME/work/wt/ilp32-6.12.y}")
T=aarch64-linux-gnu_ilp32
PREFIX=$TOP/out
HOSTPREFIX=$TOP/out-host
SYSROOT=$PREFIX/$T/sysroot
SRC=$TOP/src
B=$TOP/build
LOGS=$TOP/logs
MUSL_TC_SRC=${MUSL_WORK:-$HOME/work/ilp32-musl}/toolchain/src   # tarballs already downloaded and checked there
GNU_MIRROR=${GNU_MIRROR:-https://ftpmirror.gnu.org/gnu}
AUTOCONF=autoconf-2.72
BINUTILS=binutils-2.44
BINUTILS_SHA256=ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237
GCC=gcc-14.3.0
GCC_SHA256=e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a
J=${J:-2}          # at most -j2 on this VM (shared with other builds)
export PATH=$PREFIX/bin:$HOSTPREFIX/bin:$PATH
export MAKEINFO=true          # documentation is not needed
mkdir -p "$SRC" "$B" "$LOGS" "$SYSROOT/usr/include"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
step() { # <name> <function>: run once, output to logs/<name>.log
	if [ -f "$B/.$1" ]; then log "$1: done before, skipped"; return; fi
	log "$1 ($(date +%H:%M))"
	# set -e is ignored inside a condition, so run the step in a subshell with -e and check its status
	local rc=0
	( set -e; "$2" ) > "$LOGS/$1.log" 2>&1 || rc=$?
	if [ $rc -ne 0 ]; then echo "FAILED: $1, see $LOGS/$1.log"; tail -30 "$LOGS/$1.log"; exit 1; fi
	touch "$B/.$1"
}

fetch() { # <file> <url> [sha256]
	[ -f "$SRC/$1" ] || cp "$MUSL_TC_SRC/$1" "$SRC/$1" 2>/dev/null || wget -nv -O "$SRC/$1" "$2"
	[ -z "${3:-}" ] || echo "$3  $SRC/$1" | sha256sum -c
}

do_autoconf() {
	fetch $AUTOCONF.tar.xz $GNU_MIRROR/autoconf/$AUTOCONF.tar.xz
	gpgv --version > /dev/null 2>&1 || true
	rm -rf "$B/$AUTOCONF"
	tar -C "$B" -xf "$SRC/$AUTOCONF.tar.xz"
	cd "$B/$AUTOCONF"
	./configure --prefix="$HOSTPREFIX"
	make -j"$J"
	make install
	"$HOSTPREFIX/bin/autoconf" --version | head -1
}

do_sources() {
	fetch $BINUTILS.tar.xz $GNU_MIRROR/binutils/$BINUTILS.tar.xz $BINUTILS_SHA256
	fetch $GCC.tar.xz $GNU_MIRROR/gcc/$GCC/$GCC.tar.xz $GCC_SHA256
	rm -rf "$SRC/$BINUTILS" "$SRC/$GCC"
	tar -C "$SRC" -xf "$SRC/$BINUTILS.tar.xz"
	tar -C "$SRC" -xf "$SRC/$GCC.tar.xz"
	cd "$SRC/$GCC"
	for p in "$R"/patches/$GCC/*.patch; do
		[ -e "$p" ] || continue
		echo "patch $(basename "$p")"
		patch -p1 < "$p"
	done
	./contrib/download_prerequisites
}

do_binutils() {
	rm -rf "$B/binutils"; mkdir -p "$B/binutils"; cd "$B/binutils"
	"$SRC/$BINUTILS/configure" --target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" \
		--enable-deterministic-archives --enable-plugins --enable-lto --disable-gprofng \
		--disable-multilib --disable-werror --disable-nls --disable-sim --disable-gdb
	make -j"$J"
	make install
}

do_gcc1() {
	rm -rf "$B/gcc1"; mkdir -p "$B/gcc1"; cd "$B/gcc1"
	"$SRC/$GCC/configure" --target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" \
		--with-abi=ilp32 --with-multilib-list=ilp32 --disable-multilib --disable-nls --disable-werror \
		--enable-default-pie --enable-languages=c --without-headers --with-newlib --disable-shared --disable-threads \
		--disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp \
		--disable-libsanitizer --disable-libvtv --disable-libstdcxx --disable-decimal-float
	make -j"$J" all-gcc all-target-libgcc
	make install-gcc install-target-libgcc
}

do_kheaders() {
	echo "kernel $KSRC $(git -C "$KSRC" log -1 --format='%h %s' 2>/dev/null || true)"
	rm -rf "$B/kheaders"
	make -C "$KSRC" O="$B/kheaders" ARCH=arm64 INSTALL_HDR_PATH="$SYSROOT/usr" headers_install
	test -f "$SYSROOT/usr/include/asm/unistd_ilp32.h"
}

do_gcc2() {
	test -f "$SYSROOT/libilp32/libc.so.6" || { echo "glibc is not installed in $SYSROOT"; return 1; }
	rm -rf "$B/gcc2"; mkdir -p "$B/gcc2"; cd "$B/gcc2"
	"$SRC/$GCC/configure" --target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" 		--with-abi=ilp32 --with-multilib-list=ilp32 --disable-multilib --disable-nls --disable-werror 		--enable-default-pie --enable-languages=c,c++ --enable-shared --enable-threads=posix --enable-__cxa_atexit 		--disable-libsanitizer --disable-libssp --disable-libvtv --disable-decimal-float
	make -j"$J"
	make install
}

if [ "${STAGE:-1}" = 2 ]; then
	step gcc2 do_gcc2
	log "done: $("$PREFIX/bin/$T-g++" --version | head -1)"
	ls "$PREFIX/$T"/libilp32 2>/dev/null | grep -E '^lib(gcc_s|stdc\+\+|atomic)\.so' || true
	exit 0
fi

step autoconf do_autoconf
step sources do_sources
step binutils do_binutils
step gcc1 do_gcc1
step kheaders do_kheaders
log "done: $PREFIX/bin/$T-gcc $("$PREFIX/bin/$T-gcc" -dumpversion), multi-os-directory $("$PREFIX/bin/$T-gcc" -print-multi-os-directory)"
