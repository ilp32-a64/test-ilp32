#!/bin/bash
# Negative test of the ILP32 vDSO relocation check: add a .rodata pointer to an undefined symbol
# (a dynamic R_AARCH64_P32_ABS32 relocation; .data is discarded by the linker script), expect the vDSO link
# to fail with "dynamic relocations are not supported", then restore the file.
# Needs a configured build directory: run build.sh <branch> first.
# Usage: test-vdso-check.sh <branch>
set -u
. "$(dirname "$0")/env.sh"
BR=${1:?usage: $0 <branch>}
WT=$(kernel_wt $BR)
F=arch/arm64/kernel/vdso-ilp32/vgettimeofday.c
SAVE=$(mktemp)
cp $WT/$F $SAVE
cat >> $WT/$F <<'EOF'

extern int ilp32_vdso_reloc_test_sym;
int * const ilp32_vdso_reloc_test __attribute__((section(".rodata"), used)) = &ilp32_vdso_reloc_test_sym;
EOF
rc=1
if make -s -C $WT O=$KERNEL_BUILD/$BR -j$JOBS Image 2>&1 | grep -q "dynamic relocations are not supported"; then
	echo "==> PASS: vDSO link refused the relocation"; rc=0
else
	echo "==> FAIL: vDSO link did not refuse the relocation"
fi
cp $SAVE $WT/$F; rm -f $SAVE
git -C $WT status --short --untracked-files=no
exit $rc
