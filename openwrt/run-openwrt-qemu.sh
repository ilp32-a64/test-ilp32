#!/bin/bash
# Boot the OpenWrt armsr/armv8 ILP32 initramfs image in QEMU and run the system and C library checks
# (openwrt-qemu-test.py). The image is not changed: a second initramfs (-initrd) is unpacked over the
# built-in one and adds the test programs (/tests) and, with NOTIME32=1, /notime32-init, which forbids the
# time32 and stat64 system calls of the ILP32 ABI with seccomp for the whole system (procd and everything
# it starts), so any program that still makes one of them is killed with SIGSYS.
#
# Usage: run-openwrt-qemu.sh                 normal run
#        NOTIME32=1 run-openwrt-qemu.sh      with the seccomp filter
# Environment: OPENWRT (tree, default ~/work/openwrt-ilp32), OUT (default openwrt/out[-notime32] in this
#              tree), QEMU_CPU (default cortex-a53),
#              BOOT_TIMEOUT (seconds, default 600)
# Exit code: number of failed checks (0 = all passed).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OPENWRT=${OPENWRT:-$HOME/work/openwrt-ilp32}
ILP32_TEST=$(dirname "$HERE")
NOTIME32=${NOTIME32:-0}
OUT=${OUT:-$HERE/out$([ "$NOTIME32" = 1 ] && echo -notime32 || true)}

# ILP32 images are in armv8-ilp32 (rules.mk BIN_DIR suffix); older trees used armv8
KERNEL=$(ls "$OPENWRT"/bin/targets/armsr/armv8-ilp32/openwrt-armsr-armv8-generic-initramfs-kernel.bin 2>/dev/null ||
	ls "$OPENWRT"/bin/targets/armsr/armv8/openwrt-armsr-armv8-generic-initramfs-kernel.bin)
TC=$(ls -d "$OPENWRT"/staging_dir/toolchain-aarch64_generic_ilp32_gcc-*_musl | head -1)
T=aarch64-openwrt-linux-musl_ilp32
export STAGING_DIR=$OPENWRT/staging_dir
CC="$TC/bin/$T-gcc"
CFLAGS="-O2 -Wall"
R=$ILP32_TEST/musl/test

rm -rf "$OUT"; mkdir -p "$OUT/root/tests" "$OUT/root/usr/lib"
W=$OUT/root
# the C library tests, linked against the musl of the toolchain; the dynamic one runs with the libc of the image
$CC -static $CFLAGS -o "$W/tests/musl-test-static" "$R/musl-test.c" -lpthread
$CC $CFLAGS -o "$W/tests/musl-test-dynamic" "$R/musl-test.c" -ldl -lpthread
$CC -shared -fPIC $CFLAGS -o "$W/usr/lib/libtlsmod.so" "$R/tlsmod.c"
if [ "$NOTIME32" = 1 ]; then
	$CC -static $CFLAGS -o "$W/notime32-init" "$ILP32_TEST/qemu/notime32-init.c"
	ln -s init "$W/init.real"
	RDINIT="rdinit=/notime32-init"
else
	# raw system calls without a C library, time32 included: only without the seccomp filter
	$CC -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -Wl,--build-id=none \
		-o "$W/tests/syscall-test-ilp32" "$ILP32_TEST/tests/syscall-test.c" -lgcc
	RDINIT=
fi
"$TC/bin/$T-strip" "$W"/tests/* "$W/usr/lib/libtlsmod.so" ${RDINIT:+"$W/notime32-init"}
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet) > "$OUT/extra.cpio"

exec python3 -I "$HERE/openwrt-qemu-test.py" --kernel "$KERNEL" --initrd "$OUT/extra.cpio" \
	--append "console=ttyAMA0 panic=-1 $RDINIT" --cpu "${QEMU_CPU:-cortex-a53}" \
	--log "$OUT/serial.log" --boot-timeout "${BOOT_TIMEOUT:-600}" $([ "$NOTIME32" = 1 ] && echo --notime32)
