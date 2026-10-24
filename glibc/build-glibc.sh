#!/bin/bash
# Build glibc for AArch64 ILP32 with the stage 1 toolchain (toolchain/build-toolchain.sh) and install it
# into the toolchain sysroot.
#
#   build-glibc.sh [steps...]       steps: configure syscalls build install (default all, in this order)
#   GLIBC_SRC=<glibc tree>          (default ~/work/glibc-ilp32-2.41, branch ilp32-2.41)
#
# syscalls: the bootstrap of <arch-syscall.h> for a new ABI (sysdeps/unix/sysv/linux/Makefile): an empty
# sysdeps/unix/sysv/linux/aarch64/ilp32/arch-syscall.h, then `make update-syscall-lists' in the configured
# tree generates it from the kernel headers of the sysroot. It changes the glibc source tree.
# Output: build/ (build tree), logs/<step>.log
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${GLIBC_WORK:-$HOME/work/ilp32-glibc}	# toolchain, builds and results (not in git)
mkdir -p "$WORK"
cd "$WORK"
TOP=$PWD
T=aarch64-linux-gnu_ilp32
TC=$TOP/toolchain/out
SYSROOT=$TC/$T/sysroot
GLIBC_SRC=$(realpath "${GLIBC_SRC:-$HOME/work/glibc-ilp32-2.41}")
B=$TOP/build
LOGS=$TOP/logs
J=${J:-2}          # at most -j2 on this VM (shared with other builds)
export PATH=$TC/bin:$TOP/toolchain/out-host/bin:$PATH
mkdir -p "$B" "$LOGS"
STEPS=${*:-configure syscalls build install}

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
run() { # <step> <function>
	log "$1 ($(date +%H:%M))"
	# set -e does not work in a subshell that is part of a condition, also not left of ||, so run it
	# as a plain command with errexit off here and check its status
	local rc
	set +e
	( set -e; "$2" ) > "$LOGS/$1.log" 2>&1
	rc=$?
	set -e
	if [ $rc -ne 0 ]; then echo "FAILED: $1, see $LOGS/$1.log"; tail -40 "$LOGS/$1.log"; exit 1; fi
}

# CFLAGS: the usual -O2 -g, with the build machine's paths mapped (__FILE__, assert, debug info). glibc
# gives the assembler only the -g and -fdebug-prefix-map options of CFLAGS, so the maps are given both
# ways.
GLIBC_CFLAGS="-O2 -g"
for m in "$GLIBC_SRC=/usr/src/glibc-2.41" "$B=/usr/src/glibc-2.41/build" "$TC=/usr" "$SYSROOT="; do
	GLIBC_CFLAGS="$GLIBC_CFLAGS -ffile-prefix-map=$m -fdebug-prefix-map=$m"
done
do_configure() {
	echo "glibc $GLIBC_SRC $(git -C "$GLIBC_SRC" log -1 --format='%h %s')"
	rm -rf "$B"; mkdir -p "$B"; cd "$B"
	"$GLIBC_SRC/configure" --host=$T --build="$(gcc -dumpmachine)" --prefix=/usr \
		--with-headers="$SYSROOT/usr/include" CC="$T-gcc" CXX=false \
		CFLAGS="$GLIBC_CFLAGS"
	grep -E '^(config-machine|default-abi|slibdir|rtlddir|libdir|build-mathvec) ' config.make
	grep '^config-sysdirs' config.make | tr ' ' '\n' | grep sysdeps
}

do_syscalls() {
	local f=$GLIBC_SRC/sysdeps/unix/sysv/linux/aarch64/ilp32/arch-syscall.h
	[ -f "$f" ] || : > "$f"
	cd "$B"
	make update-syscall-lists
	wc -l "$f"
	git -C "$GLIBC_SRC" status -s -- sysdeps/unix/sysv/linux/syscall-names.list
}

do_build() {
	cd "$B"
	make -j"$J"
}

do_install() {
	cd "$B"
	make install DESTDIR="$SYSROOT"
	# GCC looks for the start files in <sysroot>/usr/lib/../libilp32: usr/lib must exist for that path
	mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/lib"
	ls -la "$SYSROOT/lib/"ld-linux-aarch64*_ilp32.so.1 "$SYSROOT/libilp32/libc.so.6"
}

for s in $STEPS; do run "$s" "do_$s"; done
log "done"
