#!/bin/bash
# Full test of ILP32 kernel branches: toolchain (once), tests, initramfs, then for each branch a full build
# with AArch32 (kernel/build.sh) and the AArch32 on/off QEMU test (kernel/verify.sh).
# Usage: run-all.sh [branch ...]      (default: ilp32-6.6)
# Kernel trees: see kernel/env.sh (KERNEL_REPO, KERNEL_WT, KERNEL_BUILD).
set -u
cd "$(dirname "$0")"
. kernel/env.sh
BRANCHES=("${@:-ilp32-6.6}")
./toolchain/build-toolchain.sh "$(kernel_wt ${BRANCHES[0]})" || exit 1
./tests/build.sh && ./qemu/make-initramfs.sh || exit 1
rc=0
for br in "${BRANCHES[@]}"; do
	echo "######## $br"
	./kernel/build.sh $br a32 || rc=1
	./kernel/verify.sh $br || rc=1
done
echo "==> run-all: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
