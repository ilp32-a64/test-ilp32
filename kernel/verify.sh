#!/bin/bash
# Build and test an ILP32 branch with AArch32 on and off:
#   1. build.sh <branch> noa32                     arm64 defconfig, ILP32 without AArch32
#   2. QEMU kernel AARCH32_EL0=n + QEMU test        AArch32 programs must be refused (ENOEXEC)
#   3. QEMU kernel AARCH32_EL0=y + QEMU test        AArch32 programs must run
#   4. ELF loader initcalls of each QEMU vmlinux   one per ABI, no duplicate
# Needs the toolchain, tests/out and qemu/out/initramfs.cpio.gz (run-all.sh does all of it).
# Usage: verify.sh <branch>
set -u
. "$(dirname "$0")/env.sh"
T=$(cd "$(dirname "$0")/.." && pwd)
BR=${1:?usage: $0 <branch>}
WT=$(kernel_wt $BR)
rc=0
$T/kernel/build.sh $BR noa32 || rc=1
for v in noa32 a32; do
	N=$BR-$v
	if [ $v = noa32 ]; then extra="-d AARCH32_EL0"; a32=0; else extra=""; a32=1; fi
	echo "==> QEMU kernel $N"
	if KCONFIG_EXTRA="$extra" $T/qemu/build-kernel.sh $WT $N > $T/qemu/out/build-$N.log 2>&1; then
		tail -1 $T/qemu/out/build-$N.log
		echo "==> ELF loaders in $N: $(${CROSS_COMPILE}nm $KERNEL_BUILD/qemu-$N/vmlinux \
			| grep -oE '__initcall_+(kmod_)?[a-z0-9_]*(elf_binfmt|binfmt_elf|binfmt_elf32|binfmt_ilp32)[a-z0-9_]*' \
			| sed -E 's/__[0-9]+_[0-9]+_.*//' | sort | tr '\n' ' ')"
		AARCH32=$a32 $T/qemu/run.sh $N > $T/qemu/out/result-$N.txt; r=$?
		grep -E "aarch32-test:|ILP32-TEST-RESULT" $T/qemu/out/result-$N.txt
		[ $r = 0 ] || { echo "==> QEMU test $N: FAIL"; rc=1; }
	else
		echo "==> BUILD FAILED $N"; grep -E "error:|unmet|not y" $T/qemu/out/build-$N.log | head -10; rc=1
	fi
done
echo "==> verify $BR: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
