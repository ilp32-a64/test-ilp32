#!/bin/bash
# Kernel for the QEMU test (machine virt) from an ILP32 kernel tree: upstream arm64 defconfig + ILP32
# + COMPAT_32BIT_TIME, everything built in (no modules).
# Usage: build-kernel.sh <kernel source tree> <name>    e.g. build-kernel.sh ~/work/wt/ilp32-6.6 ilp32-6.6
#   KCONFIG_EXTRA="<scripts/config options>"  applied last, e.g. "-d AARCH32_EL0" (ILP32 without AArch32)
# Output: qemu/out/Image-<name>, qemu/out/config-<name>; build directory $KERNEL_BUILD/qemu-<name>
set -e
S=$(realpath "${1:?usage: build-kernel.sh <kernel source tree> <name>}")
N=${2:?usage: build-kernel.sh <kernel source tree> <name>}
cd "$(dirname "$0")"
Q=$PWD
. ../kernel/env.sh
O=$KERNEL_BUILD/qemu-$N
M="make -C $S O=$O"
mkdir -p "$O" "$Q/out"
echo "==> $N: $(git -C "$S" log -1 --format='%h %s')"
$M -s defconfig
$S/scripts/config --file $O/.config \
	--disable MODULES --disable ARM64_PTR_AUTH \
	--enable COMPAT --enable AARCH32_EL0 --enable ARM64_ILP32 --enable COMPAT_32BIT_TIME \
	--enable BLK_DEV_INITRD --enable DEVTMPFS --enable TMPFS --enable SERIAL_AMBA_PL011 \
	--enable SERIAL_AMBA_PL011_CONSOLE
[ -n "${KCONFIG_EXTRA:-}" ] && $S/scripts/config --file $O/.config $KCONFIG_EXTRA
$M -s olddefconfig 2>&1 | tee $O/olddefconfig.log
grep -q "unmet direct dependencies" $O/olddefconfig.log && { echo "Kconfig: unmet dependencies"; exit 1; }
# COMPAT_32BIT_TIME: defconfig has COMPAT off, so its default (y with COMPAT) is not applied by itself;
# ILP32 glibc 2.30 has a 32-bit time_t and needs the time32 system calls (clock_gettime, futex, ...)
for o in COMPAT ARM64_ILP32 COMPAT_32BIT_TIME BLK_DEV_INITRD DEVTMPFS SERIAL_AMBA_PL011_CONSOLE; do
	grep -q "^CONFIG_$o=y" $O/.config || { echo "CONFIG_$o is not y"; exit 1; }
done
echo "==> $(grep -E '^(# )?CONFIG_AARCH32_EL0[= ]' $O/.config)"
echo "==> build Image ($(date +%H:%M))"
$M -s -j"$JOBS" Image
cp $O/arch/arm64/boot/Image "$Q/out/Image-$N"
cp $O/.config "$Q/out/config-$N"
echo "==> $Q/out/Image-$N ($(stat -c %s "$Q/out/Image-$N") bytes, $(cat $O/include/config/kernel.release))"
