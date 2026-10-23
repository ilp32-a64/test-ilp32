#!/bin/bash
# Memory use of an OpenWrt armsr/armv8 image in QEMU (-cpu cortex-a53 -smp 2 -m 256): boot RUNS times (a fresh
# copy of the image each time), wait for procd's "init complete" plus SETTLE seconds, and collect
# /proc/meminfo, free, RSS and PSS of every user process and binary sizes (openwrt-memory.py). Used to
# compare an ILP32 and an LP64 build of the same tree and configuration (summarize-memory.py).
#
# Usage: measure-memory.sh <image dir> <name> [initramfs|squashfs]...
#   <image dir>  directory with openwrt-armsr-armv8-generic-initramfs-kernel.bin and/or
#                openwrt-armsr-armv8-generic-squashfs-combined-efi.img.gz
#   squashfs boots the combined EFI image from a virtio disk with the AAVMF firmware, like a real device
# Environment: RUNS (default 3), SETTLE (default 60), MEM (default 256), OUT (default openwrt/out-memory),
#              WORKLOAD (file of commands run before settling, e.g. openwrt/workload-loaded.txt)
# Results: $OUT/<name>-<mode>-<run>.json and .log
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$(cd "${1:?usage}" && pwd); NAME=${2:?usage}; shift 2
MODES=${*:-initramfs squashfs}
RUNS=${RUNS:-3}; SETTLE=${SETTLE:-60}; MEM=${MEM:-256}
OUT=${OUT:-$HERE/out-memory}
FW=/usr/share/AAVMF/AAVMF_CODE.fd; FWVARS=/usr/share/AAVMF/AAVMF_VARS.fd
mkdir -p "$OUT"
BASE="qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m $MEM -nographic -no-reboot \
 -netdev user,id=lan -device virtio-net-pci,netdev=lan -netdev user,id=wan -device virtio-net-pci,netdev=wan"

for mode in $MODES; do
	for i in $(seq "$RUNS"); do
		tag=$NAME-$mode-$i; w=$OUT/$tag.work; rm -rf "$w"; mkdir -p "$w"
		case $mode in
		initramfs)
			q="$BASE -kernel $DIR/openwrt-armsr-armv8-generic-initramfs-kernel.bin -append console=ttyAMA0" ;;
		squashfs)
			gunzip -c "$DIR/openwrt-armsr-armv8-generic-squashfs-combined-efi.img.gz" > "$w/disk.img" || true
			cp "$FWVARS" "$w/vars.fd"
			q="$BASE -drive if=pflash,format=raw,readonly=on,file=$FW -drive if=pflash,format=raw,file=$w/vars.fd \
 -drive file=$w/disk.img,if=virtio,format=raw" ;;
		*) echo "unknown mode $mode"; exit 2 ;;
		esac
		echo "== $tag"
		python3 -I "$HERE/openwrt-memory.py" --qemu "$q" --settle "$SETTLE" --log "$OUT/$tag.log" --out "$OUT/$tag.json" \
			${WORKLOAD:+--workload "$WORKLOAD"}
		rm -rf "$w"
	done
done
