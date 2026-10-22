#!/bin/bash
# AArch64 ILP32 musl cross toolchain, stage 1: binutils 2.44 + GCC 14.3.0 (C only, no C library),
# the versions and patches of OpenWrt 25.12 (toolchain/binutils, toolchain/gcc patches-14.x).
#
#   build-stage1.sh
#
#   target          aarch64-linux-musl_ilp32 (GCC default -mabi=ilp32)
#   prefix          out/ (tools prefixed with the target), sysroot out/aarch64-linux-musl_ilp32/sysroot
#   sources         src/, build directories build/, logs logs/
#
# Stage 1 is enough to check the code generation (ELF32, R_AARCH64_P32_* relocations, PIC, TLS) and
# to build musl; stage 2 (libgcc_s, libstdc++) comes after musl. Each step leaves a stamp file
# (build/.<step>) and is skipped when re-run; delete the stamp to redo a step.
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/toolchain"
cd "$WORK/toolchain"
TOP=$PWD
T=aarch64-linux-musl_ilp32
PREFIX=$TOP/out
SYSROOT=$PREFIX/$T/sysroot
SRC=$TOP/src
B=$TOP/build
LOGS=$TOP/logs
BINUTILS=binutils-2.44
BINUTILS_SHA256=ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237
GCC=gcc-14.3.0
GCC_SHA256=e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a
OPENWRT_REF=${OPENWRT_REF:-openwrt-25.12}
GNU_MIRROR=${GNU_MIRROR:-https://ftpmirror.gnu.org/gnu}
J=${J:-2}          # at most -j2 on this VM (shared with other builds)
export PATH=$PREFIX/bin:$PATH
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

fetch() { # <name> <dir> <sha256>
	local f=$1.tar.xz
	[ -f "$SRC/$f" ] || wget -nv -O "$SRC/$f" "$GNU_MIRROR/$2/$f"
	echo "$3  $SRC/$f" | sha256sum -c
}

do_sources() {
	fetch $BINUTILS binutils $BINUTILS_SHA256
	fetch $GCC gcc/$GCC $GCC_SHA256
	# OpenWrt toolchain patches, only toolchain/binutils and toolchain/gcc
	rm -rf "$SRC/openwrt"
	git clone --depth 1 --filter=blob:none --sparse -b "$OPENWRT_REF" \
		https://github.com/openwrt/openwrt.git "$SRC/openwrt"
	git -C "$SRC/openwrt" sparse-checkout set toolchain/binutils toolchain/gcc
	git -C "$SRC/openwrt" log -1 --format='openwrt %H %cd'
}

apply_patches() { # <source dir> <patch dir>
	local p
	[ -d "$2" ] || { echo "no patches in $2"; return; }
	for p in "$2"/*.patch; do
		echo "patch $(basename "$p")"
		patch -d "$1" -p1 --no-backup-if-mismatch < "$p"
	done
}

do_unpack() {
	rm -rf "$SRC/$BINUTILS" "$SRC/$GCC"
	tar -C "$SRC" -xf "$SRC/$BINUTILS.tar.xz"
	tar -C "$SRC" -xf "$SRC/$GCC.tar.xz"
	apply_patches "$SRC/$BINUTILS" "$SRC/openwrt/toolchain/binutils/patches/${BINUTILS#binutils-}"
	apply_patches "$SRC/$GCC" "$SRC/openwrt/toolchain/gcc/patches-14.x"
	# as OpenWrt toolchain/gcc/common.mk: no multilib OS directories, target libraries in lib/
	# (for ILP32 instead of ../libilp32, the musl convention)
	sed -i 's,^MULTILIB_OSDIRNAMES,# MULTILIB_OSDIRNAMES,' "$SRC/$GCC"/gcc/config/*/t-*
}

do_prereqs() { # GMP, MPFR, MPC and ISL in the GCC tree (versions and checksums from GCC)
	cd "$SRC/$GCC"
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
		--enable-languages=c --without-headers --with-newlib --disable-shared --disable-threads \
		--disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp \
		--disable-libsanitizer --disable-libvtv --disable-libstdcxx --disable-decimal-float
	make -j"$J" all-gcc all-target-libgcc
	make install-gcc install-target-libgcc
}

step sources do_sources
step unpack do_unpack
step prereqs do_prereqs
step binutils do_binutils
step gcc1 do_gcc1
log "done: $PREFIX/bin/$T-gcc"
"$PREFIX/bin/$T-gcc" --version | head -1
