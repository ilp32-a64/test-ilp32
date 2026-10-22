#!/bin/bash
# Boot an ILP32 kernel with the test initramfs in QEMU (machine virt, Cortex-A35 or QEMU_CPU, 2 cores, 256 MB), run the
# tests and power off. Console log: qemu/out/serial-<name>.log; summary on stdout.
# Usage: run.sh <name>      (kernel qemu/out/Image-<name>, see build-kernel.sh)
#   AARCH32=0  the kernel has no AARCH32_EL0: AArch32 test programs must be refused (ENOEXEC)
#   QEMU_CPU   CPU model, default cortex-a35 (e.g. max: pointer authentication, BTI, SVE)
# QEMU user mode has no AArch64 ILP32 support; system emulation runs our own kernel.
set -e
N=${1:?usage: run.sh <name>}
cd "$(dirname "$0")"
LOG=out/serial-$N.log
timeout "${QEMU_TIMEOUT:-600}" qemu-system-aarch64 -M virt -cpu "${QEMU_CPU:-cortex-a35}" -smp 2 -m "${QEMU_MEM:-256}" \
	-nographic -no-reboot -kernel out/Image-$N -initrd out/initramfs.cpio.gz \
	-append "console=ttyAMA0 rdinit=/init panic=-1 ilp32test.aarch32=${AARCH32:-1}" < /dev/null > "$LOG" 2>&1 || true
grep -a -E 'ILP32-TEST|##########|ok |FAIL|sizeof|clock_gettime|vDSO|vdso|uname|Kernel panic|Unable to handle' "$LOG" \
	| sed 's/\x1b\[[0-9;]*m//g; s/\r$//'
grep -q 'ILP32-TEST-RESULT: 0 of' "$LOG"
