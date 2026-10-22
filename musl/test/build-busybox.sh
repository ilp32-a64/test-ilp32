#!/bin/bash
# Static ILP32 busybox (1.37.0, the version of OpenWrt 25.12) for the QEMU test initramfs: /bin/sh, echo
# and the other applets that libc-test runs (popen, posix_spawn, vfork, wordexp, execle).
#
#   build-busybox.sh            output out/busybox
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/test"
cd "$WORK/test"
TOP=$PWD
T=aarch64-linux-musl_ilp32
TC=$TOP/../toolchain/out
V=busybox-1.37.0
SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
SRC=$TOP/src
mkdir -p "$SRC" out
[ -f "$SRC/$V.tar.bz2" ] || wget -nv -O "$SRC/$V.tar.bz2" "https://www.busybox.net/downloads/$V.tar.bz2"
echo "$SHA256  $SRC/$V.tar.bz2" | sha256sum -c
rm -rf "$SRC/$V"
tar -C "$SRC" -xf "$SRC/$V.tar.bz2"
cd "$SRC/$V"
# OpenWrt's fix for building 1.37.0 on non-x86 (sha1_process_block64_shaNI)
patch -p1 < "${OPENWRT:-$HOME/work/openwrt-ilp32}/package/utils/busybox/patches/001-fix-non-x86-build.patch"
make -s CROSS_COMPILE="$TC/bin/$T-" defconfig
# static; tc does not build with current kernel headers (CBQ was removed from the uapi)
sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
make -s CROSS_COMPILE="$TC/bin/$T-" oldconfig < /dev/null > /dev/null
make -s -j"${J:-2}" CROSS_COMPILE="$TC/bin/$T-" busybox
cp busybox "$TOP/out/busybox"
"$TC/bin/$T-readelf" -h "$TOP/out/busybox" | grep -E 'Class|Type'
"$TC/bin/$T-strip" "$TOP/out/busybox"
ls -la "$TOP/out/busybox"
