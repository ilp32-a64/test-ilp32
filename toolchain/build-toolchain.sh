#!/bin/bash
# AArch64 ILP32 cross toolchain: binutils 2.35.2, GCC 10.5 (GNU release tarballs), glibc 2.30 (branch
# ilp32-2.30 of ilp32-a64/glibc-ilp32 = sourceware arm/ilp32 + fixes), kernel headers from an ILP32 kernel tree.
#
#   build-toolchain.sh [kernel source tree]      (default ~/work/wt/ilp32-6.6)
#   GLIBC_REPO=<url or path> GLIBC_REF=<branch>  other glibc source (default ilp32-a64/glibc-ilp32 ilp32-2.30)
#
#   target          aarch64-linux-gnu_ilp32 (GCC default -mabi=ilp32)
#   dynamic linker  /lib/ld-linux-aarch64_ilp32.so.1, libraries in /libilp32 and /usr/libilp32
#   prefix          out/ (tools prefixed with the target), sysroot out/aarch64-linux-gnu_ilp32/sysroot
#   sources         src/, build directories build/, logs logs/
#
# GCC 10.5 and binutils 2.35.2 are of the same period as glibc 2.30 (newer compilers break the old glibc
# build), and GCC 10 is before the -mabi=ilp32 deprecation (GCC 15). Each step leaves a stamp file
# (build/.<step>) and is skipped when re-run; delete the stamp to redo a step.
set -euo pipefail
cd "$(dirname "$0")"
TOP=$PWD
KSRC=$(realpath "${1:-$HOME/work/wt/ilp32-6.6}")
T=aarch64-linux-gnu_ilp32
PREFIX=$TOP/out
SYSROOT=$PREFIX/$T/sysroot
SRC=$TOP/src
B=$TOP/build
LOGS=$TOP/logs
BINUTILS=binutils-2.35.2
GCC=gcc-10.5.0
# glibc 2.30 with AArch64 ILP32: sourceware branch arm/ilp32 + our fixes (branch ilp32-2.30)
GLIBC_REPO=${GLIBC_REPO:-https://github.com/ilp32-a64/glibc-ilp32.git}
GLIBC_REF=${GLIBC_REF:-ilp32-2.30}
J=${JOBS:-$(nproc)}
export PATH=$PREFIX/bin:$PATH
export MAKEINFO=true          # documentation is not needed
mkdir -p "$SRC" "$B" "$LOGS"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
step() { # <name> <function>: run once, output to logs/<name>.log
	if [ -f "$B/.$1" ]; then log "$1: done before, skipped"; return; fi
	log "$1 ($(date +%H:%M))"
	if ! "$2" > "$LOGS/$1.log" 2>&1; then echo "FAILED: $1, see $LOGS/$1.log"; tail -30 "$LOGS/$1.log"; exit 1; fi
	touch "$B/.$1"
}

fetch() {
	cd "$SRC"
	for f in $BINUTILS.tar.xz $GCC.tar.xz; do
		d=${f%.tar.xz}
		case $d in binutils*) u=https://ftp.gnu.org/gnu/binutils/$f ;; gcc*) u=https://ftp.gnu.org/gnu/gcc/$d/$f ;; esac
		[ -f "$f" ] || wget -q "$u"
		[ -d "$d" ] || tar xf "$f"
	done
	sha256sum $BINUTILS.tar.xz $GCC.tar.xz > SHA256SUMS
	(cd $GCC && ./contrib/download_prerequisites)          # gmp, mpfr, mpc, isl (checked by the script)
	if [ ! -d glibc/.git ]; then git init -q glibc; git -C glibc remote add origin "$GLIBC_REPO"; fi
	git -C glibc fetch -q --depth 1 "$GLIBC_REPO" $GLIBC_REF
	git -C glibc checkout -q --force FETCH_HEAD
	git -C glibc log -1 --format='glibc %H %ci %s'
	grep VERSION glibc/version.h
}

binutils() {
	rm -rf "$B/binutils"; mkdir -p "$B/binutils"; cd "$B/binutils"
	"$SRC/$BINUTILS/configure" --target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" \
		--disable-nls --disable-werror --disable-multilib --disable-gdb --disable-sim
	make -j$J; make install
}

headers() {
	# separate object directory: headers_install inside the source tree breaks later O= builds of it
	echo "kernel headers from $KSRC ($(git -C "$KSRC" log -1 --format='%h %s' 2>/dev/null || echo 'not a git tree'))"
	make -C "$KSRC" O="$B/kheaders" ARCH=arm64 INSTALL_HDR_PATH="$SYSROOT/usr" headers_install
	ls "$SYSROOT/usr/include/asm/unistd.h"
}

GCC_COMMON=(--target=$T --prefix="$PREFIX" --with-sysroot="$SYSROOT" --with-abi=ilp32
	--with-multilib-list=ilp32 --disable-multilib --disable-nls --disable-libsanitizer --disable-werror)

gcc1() {
	rm -rf "$B/gcc1"; mkdir -p "$B/gcc1"; cd "$B/gcc1"
	"$SRC/$GCC/configure" "${GCC_COMMON[@]}" --enable-languages=c --without-headers --with-newlib \
		--disable-shared --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath \
		--disable-libssp --disable-libvtv --disable-libstdcxx --disable-decimal-float
	make -j$J all-gcc all-target-libgcc
	make install-gcc install-target-libgcc
	# glibc links some helpers statically with -lgcc_eh; the static-only libgcc has no separate libgcc_eh
	d=$(dirname "$($T-gcc -print-libgcc-file-name)"); ln -sf libgcc.a "$d/libgcc_eh.a"
}

glibc() {
	rm -rf "$B/glibc"; mkdir -p "$B/glibc"; cd "$B/glibc"
	"$SRC/glibc/configure" --host=$T --build="$(gcc -dumpmachine)" --prefix=/usr \
		CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib \
		--with-headers="$SYSROOT/usr/include" --enable-kernel=5.10 --disable-werror \
		--disable-profile --without-selinux --disable-crypt
	make -j$J
	make install install_root="$SYSROOT"
	# GCC looks for start files in <sysroot>/usr/lib/../libilp32: usr/lib must exist for that path to resolve
	mkdir -p "$SYSROOT/lib" "$SYSROOT/usr/lib"
	ls -l "$SYSROOT"/lib/ld-linux-*.so.* "$SYSROOT"/lib*/libc.so.6 "$SYSROOT"/usr/lib*/crt1.o
}

gcc2() {
	rm -f "$(dirname "$($T-gcc -print-libgcc-file-name)")/libgcc_eh.a"
	rm -rf "$B/gcc2"; mkdir -p "$B/gcc2"; cd "$B/gcc2"
	"$SRC/$GCC/configure" "${GCC_COMMON[@]}" --enable-languages=c,c++ --enable-shared --enable-threads=posix \
		--enable-__cxa_atexit --disable-libssp --disable-libvtv
	make -j$J
	make install
}

smoke() {
	cd "$B"
	printf '#include <stdio.h>\nint main(void){printf("hello sizeof(long)=%%zu sizeof(void*)=%%zu\\n",sizeof(long),sizeof(void*));return 0;}\n' > hello.c
	printf '#include <iostream>\n#include <string>\nint main(){std::string s="hello C++";std::cout<<s<<" "<<sizeof(long)<<std::endl;}\n' > hello.cpp
	$T-gcc -O2 -o hello-dyn hello.c
	$T-gcc -O2 -static -o hello-static hello.c
	$T-g++ -O2 -o hello-cpp hello.cpp
	for f in hello-dyn hello-static hello-cpp; do
		echo "== $f"; $T-readelf -hlW $f | grep -E 'Class|Type:|Machine|Flags|interpreter'
	done
	$T-gcc -v 2>&1 | tail -1
	echo "multi-os-directory: $($T-gcc -print-multi-os-directory)"
	# glibc must look up the ILP32 vDSO with the kernel's version (ilp32-a64/glibc-ilp32 ilp32-2.30)
	grep -c 'LINUX_4.12' "$SYSROOT"/libilp32/libc.so.6 && echo "libc.so.6 references LINUX_4.12"
}

step fetch fetch
step binutils binutils
step headers headers
step gcc1 gcc1
step glibc glibc
step gcc2 gcc2
step smoke smoke
cat "$LOGS/smoke.log"
log "toolchain ready: $PREFIX/bin/$T-gcc (sysroot $SYSROOT)"
