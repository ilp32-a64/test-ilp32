#!/bin/bash
# Build-test an ILP32 kernel branch: arm64 defconfig + ILP32, out of tree.
# Usage: build.sh <branch> [a32|noa32]
#   a32    AArch32 and ILP32 (COMPAT, AARCH32_EL0, ARM64_ILP32): Image, modules, dtbs   (default)
#   noa32  ILP32 without AArch32 (ARM64_ILP32=y, AARCH32_EL0=n): Image
# Build directory $KERNEL_BUILD/<branch> or $KERNEL_BUILD/<branch>-noa32, log next to it (<dir>.log).
set -e
. "$(dirname "$0")/env.sh"
BR=${1:?usage: $0 <branch> [a32|noa32]}
MODE=${2:-a32}
WT=$(kernel_wt $BR)
case $MODE in
a32)   OUT=$KERNEL_BUILD/$BR; CFG=(-e COMPAT -e AARCH32_EL0 -e ARM64_ILP32 -d ARM64_PTR_AUTH)
       TARGETS=(Image modules dtbs) ;;
noa32) OUT=$KERNEL_BUILD/$BR-noa32; CFG=(-e COMPAT -d AARCH32_EL0 -e ARM64_ILP32 -d ARM64_PTR_AUTH -e SECCOMP)
       TARGETS=(Image) ;;
*)     echo "usage: $0 <branch> [a32|noa32]"; exit 1 ;;
esac
M="make -C $WT O=$OUT"
mkdir -p $OUT
echo "==> $BR ($MODE) at $(git -C $WT log -1 --format='%h %s')"
[ -z "$(git -C $WT status --short --untracked-files=no)" ] || echo "==> note: work tree has changes"
echo "==> compiler: $(${CROSS_COMPILE}gcc --version | head -1)"

$M -s defconfig
# ARM64_ILP32 depends on COMPAT and !ARM64_PTR_AUTH (pointer authentication is not supported with ILP32)
$WT/scripts/config --file $OUT/.config "${CFG[@]}"
$M -s olddefconfig 2>&1 | tee $OUT/olddefconfig.log
grep -q "unmet direct dependencies" $OUT/olddefconfig.log && { echo "ERROR: Kconfig: unmet dependencies"; exit 1; }
grep -E '^(# )?CONFIG_(COMPAT|AARCH32_EL0|ARM64_ILP32|ARM64_PTR_AUTH)[= ]' $OUT/.config
grep -q '^CONFIG_ARM64_ILP32=y' $OUT/.config || { echo "ERROR: ARM64_ILP32 not enabled"; exit 1; }

echo "==> build ${TARGETS[*]} (-j$(nproc))"
start=$(date +%s)
if $M -j$(nproc) "${TARGETS[@]}" > $OUT.log 2>&1; then
	echo "==> BUILD OK in $(( $(date +%s) - start )) s"
else
	echo "==> BUILD FAILED (see $OUT.log)"; grep -nE 'error:|Error [0-9]|FORCE prerequisite' $OUT.log | head -30; exit 1
fi
echo "==> Kbuild notes (FORCE prerequisite): $(grep -c 'FORCE prerequisite' $OUT.log || true)"
echo "==> warnings in ILP32 code:"
grep -E 'warning:' $OUT.log | grep -iE 'ilp32|binfmt_elf32|signal32|sys32|vdso' | grep -v 'orphan section' \
	| sort -u | head -30 || true
V=$OUT/arch/arm64/kernel/vdso-ilp32/vdso-ilp32.so
file $V
echo "==> ILP32 vDSO: $(${CROSS_COMPILE}readelf -d $V | grep -oE '\((HASH|GNU_HASH|FLAGS)\) +[A-Z_ 0-9x]*' | tr -s ' ' | tr '\n' ';')" \
	"symbols: $(${CROSS_COMPILE}readelf -W --dyn-syms $V | grep -oE '__kernel_[a-z_0-9]+' | sort | tr '\n' ' ')"
ls -l $OUT/arch/arm64/boot/Image
