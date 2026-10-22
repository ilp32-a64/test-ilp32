#!/bin/bash
# Run the OpenWrt armsr ILP32 QEMU checks on cortex-a53 (like OpenWrt One) and on -cpu max (PAC, BTI, SVE),
# each normal and with NOTIME32=1. Prints one result line per run.
H=$(cd "$(dirname "$0")" && pwd)
for cpu in cortex-a53 max; do
	for nt in 0 1; do
		o=$H/out-$cpu$([ $nt = 1 ] && echo -notime32 || true)
		NOTIME32=$nt QEMU_CPU=$cpu OUT=$o "$H/run-openwrt-qemu.sh" > "$o.log" 2>&1
		echo "$cpu NOTIME32=$nt: $(grep "^OPENWRT-QEMU-RESULT" "$o.log") $(grep "boot took" "$o.log" | sed "s/^ *//")"
		grep "^FAIL" "$o.log" | sed "s/^/    /"
	done
done
