#!/bin/bash
# Run the OpenWrt armsr ILP32 QEMU checks on cortex-a53 (like OpenWrt One) and on -cpu max (PAC, BTI, SVE),
# each normal and with NOTIME32=1. Prints one result line per run. KERNEL, PREBUILT and OPENWRT are passed
# on to run-openwrt-qemu.sh. Exit code: number of runs with failed checks (0 = all passed).
H=$(cd "$(dirname "$0")" && pwd)
OUTBASE=${OUTBASE:-$H}
mkdir -p "$OUTBASE"
failed=0
for cpu in cortex-a53 max; do
	for nt in 0 1; do
		o=$OUTBASE/out-$cpu$([ $nt = 1 ] && echo -notime32 || true)
		NOTIME32=$nt QEMU_CPU=$cpu OUT=$o "$H/run-openwrt-qemu.sh" > "$o.log" 2>&1 || failed=$((failed + 1))
		echo "$cpu NOTIME32=$nt: $(grep "^OPENWRT-QEMU-RESULT" "$o.log" || echo "no result") $(grep "boot took" "$o.log" | sed "s/^ *//")"
		grep "^FAIL" "$o.log" | sed "s/^/    /"
	done
done
exit $failed
