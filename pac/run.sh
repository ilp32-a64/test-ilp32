#!/bin/bash
# Boot a kernel of qemu/out with pac/out/initramfs-pac.cpio.gz on a CPU with pointer authentication,
# BTI and SVE (QEMU -cpu max by default) and print the test results. Exit status 0 if all passed.
# Usage: pac/run.sh <kernel name> [cpu]    (qemu/out/Image-<kernel name>; AARCH32=0 for a kernel without
#                                          AArch32)
set -eu
cd "$(dirname "$0")"
N=${1:?usage: pac/run.sh <kernel name> [cpu]}
CPU=${2:-max}
LOG=out/serial-$N-$CPU.log
timeout "${QEMU_TIMEOUT:-1200}" qemu-system-aarch64 -M virt -cpu "$CPU" -smp 2 -m 512 \
	-nographic -no-reboot -kernel "../qemu/out/Image-$N" -initrd out/initramfs-pac.cpio.gz \
	-append "console=ttyAMA0 rdinit=/init panic=-1 ilp32test.aarch32=${AARCH32:-1}" < /dev/null > "$LOG" 2>&1 || true
sed 's/\x1b\[[0-9;]*m//g; s/\r$//' "$LOG" | grep -a -E '^(ok |FAIL|     |pac-|##########|ILP32-TEST)|Kernel panic|Unable to handle|CPU features: detected: .*(Address|Generic|authentication|BTI)' || true
grep -q 'ILP32-TEST-RESULT: 0 of' "$LOG"
