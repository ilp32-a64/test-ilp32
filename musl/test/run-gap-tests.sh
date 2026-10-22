#!/bin/bash
# The remaining musl tests, one after the other, once the machine is free (no kernel build or QEMU of
# ilp32-test running): musl built with -g (OpenWrt variant: CFI in the assembly) and the plain ilp32-1.2.5
# branch, libc-test with busybox (the shell tests), and the AArch32 kernel when its image exists.
# Results: out/gap-tests.txt
set -u
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
cd "${MUSL_WORK:-$HOME/work/ilp32-musl}/test"
K=$(realpath "$R/../..")/qemu/out
R=out/gap-tests.txt
# NOWAIT=1: start at once
[ -n "${NOWAIT:-}" ] || while pgrep -f "^make -C $HOME/work/wt/" > /dev/null || pgrep -x qemu-system-aar > /dev/null; do sleep 30; done
: > $R
run() { # <title> <command...>
	echo "##### $1 ($(date +%H:%M))" | tee -a $R
	shift
	"$@" > out/last.log 2>&1
	echo "exit $?" >> $R
	grep -a 'ILP32-TEST-RESULT\|LIBC-TEST-RESULT\|^FAIL\|########## .*: \(killed\|exit\|ran\)' out/last.log >> $R
}
run "musl-test, OpenWrt variant -g" env MUSL_BUILD=../build-musl-owrt-g "$R/run-musl-test.sh"
run "musl-test, ilp32-1.2.5 -g" env MUSL_BUILD=../build-musl-g "$R/run-musl-test.sh"
run "libc-test, OpenWrt variant -g, busybox" env ABI=ilp32 TAG=ilp32-owrt-g MUSL_BUILD=../build-musl-owrt-g "$R/run-libc-test.sh"
run "libc-test, ilp32-1.2.5 -g, busybox" env ABI=ilp32 TAG=ilp32-1.2.5-g MUSL_BUILD=../build-musl-g "$R/run-libc-test.sh"
if [ -f $K/Image-ilp32-6.12-a32 ]; then
	run "musl-test, OpenWrt variant -g, AArch32 kernel" env MUSL_BUILD=../build-musl-owrt-g "$R/run-musl-test.sh" $K/Image-ilp32-6.12-a32
	run "libc-test, OpenWrt variant -g, busybox, AArch32 kernel" env ABI=ilp32 TAG=ilp32-owrt-g-a32 MUSL_BUILD=../build-musl-owrt-g "$R/run-libc-test.sh" $K/Image-ilp32-6.12-a32
else
	echo "##### no $K/Image-ilp32-6.12-a32, AArch32 kernel skipped" | tee -a $R
fi
echo "##### done ($(date +%H:%M))" | tee -a $R
