#!/bin/bash
# AArch64 ILP32 musl cross toolchain, stage 2 (after build-stage1.sh), in the order of the OpenWrt toolchain:
# kernel headers of an ILP32 kernel tree, musl (aarch64-ilp32 branch: v1.2.5 + OpenWrt 25.12 patches + the
# ILP32 port), then the final GCC 14.3.0 with C and C++ and the OpenWrt toolchain/gcc options
# (common.mk, final/Makefile): shared libgcc, libstdc++, libatomic.
#
#   build-stage2.sh [kernel source tree]      (default ~/work/wt/ilp32-6.12.y)
#   MUSL_SRC=<musl source tree>               (default ~/work/musl-ilp32, the checked out branch is used)
#
#   musl layout as OpenWrt: libraries and the dynamic linker in /lib, headers in /usr/include
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/toolchain"
cd "$WORK/toolchain"
TOP=$PWD
KSRC=$(realpath "${1:-$HOME/work/wt/ilp32-6.12.y}")
MUSL_SRC=$(realpath "${MUSL_SRC:-$HOME/work/musl-ilp32}")
T=aarch64-linux-musl_ilp32
PREFIX=$TOP/out
SYSROOT=$PREFIX/$T/sysroot
SRC=$TOP/src
B=$TOP/build
LOGS=$TOP/logs
GCC=gcc-14.3.0
J=${J:-2}          # at most -j2 on this VM (shared with other builds)
export PATH=$PREFIX/bin:$PATH
export MAKEINFO=true          # documentation is not needed
[ -x "$PREFIX/bin/$T-gcc" ] || { echo "run build-stage1.sh first"; exit 1; }

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
step() { # <name> <function>: run once, output to logs/<name>.log
	if [ -f "$B/.$1" ]; then log "$1: done before, skipped"; return; fi
	log "$1 ($(date +%H:%M))"
	# set -e does not work in a subshell that is part of a condition, also not left of ||, so run it
	# as a plain command with errexit off here and check its status
	local rc
	set +e
	( set -e; "$2" ) > "$LOGS/$1.log" 2>&1
	rc=$?
	set -e
	if [ $rc -ne 0 ]; then echo "FAILED: $1, see $LOGS/$1.log"; tail -30 "$LOGS/$1.log"; exit 1; fi
	touch "$B/.$1"
}

do_kheaders() {
	echo "kernel $KSRC $(git -C "$KSRC" log -1 --format='%h %s' 2>/dev/null || true)"
	rm -rf "$B/kheaders"
	make -C "$KSRC" O="$B/kheaders" ARCH=arm64 INSTALL_HDR_PATH="$SYSROOT/usr" headers_install
	# the ILP32 system call numbers must be there (asm/unistd.h picks them for __ILP32__)
	test -f "$SYSROOT/usr/include/asm/unistd_ilp32.h"
}

do_musl() {
	echo "musl $MUSL_SRC $(git -C "$MUSL_SRC" log -1 --format='%h %s')"
	rm -rf "$B/musl"; mkdir -p "$B/musl"; cd "$B/musl"
	"$MUSL_SRC/configure" --target=$T --prefix=/usr --syslibdir=/lib --libdir=/lib \
		CC="$T-gcc" CROSS_COMPILE="$T-"
	make -j"$J"
	make install DESTDIR="$SYSROOT"
}

do_gcc2() {
	rm -rf "$B/gcc2"; mkdir -p "$B/gcc2"; cd "$B/gcc2"
	"$SRC/$GCC/configure" --target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" \
		--with-abi=ilp32 --with-multilib-list=ilp32 --disable-werror \
		--with-gnu-ld --enable-target-optspace --disable-libgomp --disable-libmudflap --disable-multilib \
		--disable-libmpx --disable-nls --disable-libssp --disable-decimal-float \
		--enable-__cxa_atexit --enable-libstdcxx-dual-abi --with-default-libstdcxx-abi=new \
		--enable-languages=c,c++ --enable-shared --enable-threads --enable-plugins --enable-lto \
		--disable-libsanitizer
	make -j"$J"
	make install
}

step kheaders do_kheaders
step musl do_musl
step gcc2 do_gcc2
log "done: $PREFIX/bin/$T-gcc, $PREFIX/bin/$T-g++"
"$PREFIX/bin/$T-g++" --version | head -1
ls "$PREFIX/$T/lib" | grep -E '^lib(gcc_s|stdc\+\+|atomic)\.so' || true
