#!/bin/bash
# LP64 regression check of the ILP32 changes: build pristine glibc 2.41 (release/2.41 commit of the
# branch base) and the ilp32-2.41 tree for AArch64 LP64 with the Ubuntu cross compiler, run check-abi on
# the changed tree, and compare the code of the main libraries.
#
#   lp64-check.sh [steps...]        steps: configure build compare (default all)
#   GLIBC_SRC=<changed tree>        (default ~/work/glibc-ilp32-2.41)
#   ORIG_SRC=<pristine tree>        (default /tmp/g241-orig, a detached worktree of the base commit)
# Output: lp64-check/{orig,new} build trees, logs/lp64-*.log
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${GLIBC_WORK:-$HOME/work/ilp32-glibc}	# toolchain, builds and results (not in git)
mkdir -p "$WORK"
cd "$WORK"
TOP=$PWD
GLIBC_SRC=$(realpath "${GLIBC_SRC:-$HOME/work/glibc-ilp32-2.41}")
ORIG_SRC=$(realpath "${ORIG_SRC:-/tmp/g241-orig}")
B=$TOP/lp64-check
LOGS=$TOP/logs
CROSS=aarch64-linux-gnu-
mkdir -p "$B" "$LOGS"
STEPS=${*:-configure build compare}

do_configure() {
	local n src
	for n in orig new; do
		[ $n = orig ] && src=$ORIG_SRC || src=$GLIBC_SRC
		echo "$n: $src $(git -C "$src" log -1 --format='%h %s')"
		rm -rf "$B/$n"; mkdir -p "$B/$n"
		(cd "$B/$n" && "$src/configure" --host=aarch64-linux-gnu --build="$(gcc -dumpmachine)" --prefix=/usr \
			--with-headers=/usr/aarch64-linux-gnu/include CC=${CROSS}gcc CXX=${CROSS}g++ > configure.log)
	done
}

do_build() {
	(cd "$B/orig" && make -j1 > make.log 2>&1) & p1=$!
	(cd "$B/new" && make -j1 > make.log 2>&1) & p2=$!
	wait $p1 && wait $p2
	cd "$B/new" && make check-abi > check-abi.log 2>&1
	echo "check-abi (new): $(find . -name 'check-abi-*.out' -size +0 | grep -v version | wc -l) non-empty diffs"
}

do_compare() {
	local f
	for f in libc.so elf/ld.so math/libm.so nptl/libpthread.so; do
		[ -f "$B/orig/$f" ] || continue
		${CROSS}objdump -d --no-show-raw-insn "$B/orig/$f" | tail -n +3 > "$B/orig.dis"
		${CROSS}objdump -d --no-show-raw-insn "$B/new/$f" | tail -n +3 > "$B/new.dis"
		if cmp -s "$B/orig.dis" "$B/new.dis"; then
			echo "$f: code identical ($(wc -l < "$B/orig.dis") lines)"
		else
			echo "$f: code DIFFERS ($(diff "$B/orig.dis" "$B/new.dis" | grep -c '^[<>]') lines)"
		fi
	done
}

for s in $STEPS; do
	echo "==> $s ($(date +%H:%M))"
	"do_$s" 2>&1 | tee "$LOGS/lp64-$s.log"
done
