#!/bin/bash
# The longer musl tests, one after the other, once the machine is free (no kernel build or QEMU
# running): musl-test and libc-test with busybox (the shell tests) on the kernel without AArch32, then
# both on the AArch32 kernel when its image exists. musl is MUSL_BUILD (default $MUSL_WORK/build-musl).
# Results: out/gap-tests.txt
set -u
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
cd "${MUSL_WORK:-$HOME/work/ilp32-musl}/test"
K=$(realpath "$R/../..")/qemu/out
A32=$K/Image-ilp32-6.12.y-a32
G=out/gap-tests.txt
# NOWAIT=1: start at once
[ -n "${NOWAIT:-}" ] || while pgrep -f "^make -C $HOME/work/wt/" > /dev/null || pgrep -x qemu-system-aar > /dev/null; do sleep 30; done
: > $G
run() { # <title> <command...>
	echo "##### $1 ($(date +%H:%M))" | tee -a $G
	shift
	"$@" > out/last.log 2>&1
	echo "exit $?" >> $G
	grep -a 'ILP32-TEST-RESULT\|LIBC-TEST-RESULT\|^FAIL\|########## .*: \(killed\|exit\|ran\)' out/last.log >> $G
}
run "musl-test" "$R/run-musl-test.sh"
run "libc-test, busybox" env ABI=ilp32 TAG=ilp32 "$R/run-libc-test.sh"
if [ -f $A32 ]; then
	run "musl-test, AArch32 kernel" "$R/run-musl-test.sh" $A32
	run "libc-test, busybox, AArch32 kernel" env ABI=ilp32 TAG=ilp32-a32 "$R/run-libc-test.sh" $A32
else
	echo "##### no $A32, AArch32 kernel skipped" | tee -a $G
fi
echo "##### done ($(date +%H:%M))" | tee -a $G
