#!/bin/bash
# Build an OpenWrt-ILP32 release for one target from a checked-out openwrt-ilp32 tree: feeds as pinned by
# the tree, toolchain from scratch, release/<target>.config, version strings, no package feed. Collects
# the release files (and for armsr-armv8 the test programs for the QEMU checks), and checks the public files
# for build host details. Used by the release workflow of openwrt-ilp32 and on a local machine.
#
# Usage: build-release.sh <openwrt tree> <version> <output directory> [<target>]
#   version: e.g. 25.12.6-ilp32.1 (CONFIG_VERSION_NUMBER; the tag is v<version>)
#   target:  armsr-armv8 (default) or mediatek-filogic, the name of the seed in release/
# Environment: JOBS (default: nproc), EXTRA_PATTERNS (file with more extended regexps that must not appear
#              in the public files, one per line; kept out of the repository)
# Output: <out>/release/ (images, manifests, <target>-*.buildinfo, <target>-public-info.txt,
#         sha256sums-<target>), <out>/tests/ (armsr-armv8 only: extra.cpio, extra-notime32.cpio for
#         run-openwrt-qemu.sh PREBUILT)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$(cd "${1:?usage: build-release.sh <openwrt tree> <version> <out> [<target>]}" && pwd)
VERSION=${2:?version}
mkdir -p "${3:?out}"; OUT=$(cd "$3" && pwd)
TARGET=${4:-armsr-armv8}
JOBS=${JOBS:-$(nproc)}
SEED=$HERE/release/$TARGET.config
[ -f "$SEED" ] || { echo "no seed $SEED" >&2; exit 1; }
log() { echo "== $(date -u +%H:%M:%S) $*"; }

# the release files of each target, as globs in bin/targets/<board>/<subtarget>-ilp32
case $TARGET in
armsr-armv8)
	BOARD=armsr SUBTARGET=armv8
	FILES='*-initramfs-kernel.bin *-combined-efi.img.gz' ;;
mediatek-filogic)
	# the devices of the seed (CONFIG_TARGET_DEVICE_..._DEVICE_<name>=y): their images and boot loaders
	BOARD=mediatek SUBTARGET=filogic
	DEVICES=$(sed -n 's/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_\(.*\)=y$/\1/p' "$SEED")
	FILES=$(for d in $DEVICES; do echo "*-$d-*"; done) ;;
*) echo "unknown target: $TARGET" >&2; exit 1 ;;
esac

case $VERSION in *[!0-9A-Za-z.+-]* | "") echo "bad version: $VERSION" >&2; exit 1 ;; esac
cd "$TREE"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tree has local changes" >&2; exit 1; }

# VERSION_CODE: r<upstream revision>+<commits since the upstream release>-<hash>. The upstream release
# commit is the last one that changed the "version" file (it holds the upstream code, e.g. r33311-981c978eff).
UP=$(cat version)
BASE=$(git log -1 --format=%H -- version)
[ -n "$BASE" ] || { echo "no history back to the upstream release commit (fetch more depth)" >&2; exit 1; }
# no tags needed, but in a shallow clone the boundary commit looks as if it had added every file
SHALLOW=$(git rev-parse --git-path shallow)
if [ -f "$SHALLOW" ] && grep -qx "$BASE" "$SHALLOW"; then
	echo "the upstream release commit is beyond the shallow history (fetch more depth)" >&2; exit 1
fi
N=$(git rev-list --count "$BASE"..HEAD)
CODE=${UP%%-*}+$N-$(git rev-parse --short=10 HEAD)
UPHASH=${UP##*-}
log "$TARGET, version $VERSION, code $CODE (upstream $UP, base $(git rev-parse --short=10 "$BASE"))"
# REVISION (scripts/getver.sh, from the version file) is DISTRIB_REVISION, os-release BUILD_ID, the base-files
# package version and version.buildinfo: give it our code too, not the upstream one; restored at exit
echo "$CODE" > version
trap 'git -C "$TREE" checkout -q -- version' EXIT

log "feeds (pinned by feeds.conf.default)"
./scripts/feeds update -a > "$OUT/feeds.log" 2>&1
./scripts/feeds install -a >> "$OUT/feeds.log" 2>&1

log "config"
{ grep -v '^#' "$SEED" | grep .; grep '^# CONFIG_' "$SEED" || true
  echo "CONFIG_VERSION_NUMBER=\"$VERSION\""; echo "CONFIG_VERSION_CODE=\"$CODE\""; } > .config
make defconfig > /dev/null
missing=0
while read -r line; do
	grep -qxF "$line" .config || { echo "config: not set: $line" >&2; missing=1; }
done < <(grep -E '^CONFIG_|^# CONFIG_.* is not set' "$SEED"; echo "CONFIG_VERSION_NUMBER=\"$VERSION\""; echo "CONFIG_VERSION_CODE=\"$CODE\"")
[ $missing = 0 ] || exit 1

# no package feed: the apk feed list only explains that (the default points to downloads.openwrt.org)
mkdir -p files/etc/apk/repositories.d
cat > files/etc/apk/repositories.d/distfeeds.list <<EOF
# OpenWrt-ILP32 has no package feed: the official OpenWrt packages are not built for ILP32
# (aarch64_*_ilp32). Build packages from source: https://github.com/ilp32-a64/openwrt-ilp32
EOF

# the version strings and the kernel build user/host do not make OpenWrt rebuild what an earlier build of the
# tree left: start from clean target directories (the toolchain stays; on a CI runner the tree is new anyway)
log "clean"
make clean > /dev/null

log "download"
make -j"$JOBS" download > "$OUT/download.log" 2>&1 || make -j1 download V=s >> "$OUT/download.log" 2>&1
log "build (-j$JOBS)"
if ! make -j"$JOBS" > "$OUT/build.log" 2>&1; then
	log "build failed, again with -j1 V=s for the log"
	make -j1 V=s > "$OUT/build-failed.log" 2>&1 || true
	tail -60 "$OUT/build-failed.log"; exit 1
fi

BIN=bin/targets/$BOARD/$SUBTARGET-ilp32
R=$OUT/release
mkdir -p "$R"
log "collect"
# every device must have its images (OpenWrt skips a device whose image does not fit, without failing)
for d in ${DEVICES:-}; do
	ls "$BIN"/*-"$d"-squashfs-sysupgrade.* > /dev/null 2>&1 || { echo "no sysupgrade image for $d" >&2; exit 1; }
done
(cd "$BIN" && cp $FILES *.manifest "$R/")
for f in config feeds version; do cp "$BIN/$f.buildinfo" "$R/$TARGET-$f.buildinfo"; done
(cd "$R" && ls | grep -v -e '^sha256sums' -e 'public-info' | xargs sha256sum -- > "sha256sums-$TARGET")

if [ "$TARGET" = armsr-armv8 ]; then
	log "test programs"
	for nt in 0 1; do
		OPENWRT=$TREE BUILD_ONLY=1 NOTIME32=$nt OUT="$OUT/tests/build-$nt" "$HERE/run-openwrt-qemu.sh"
	done
	cp "$OUT/tests/build-0/extra.cpio" "$OUT/tests/extra.cpio"
	cp "$OUT/tests/build-1/extra.cpio" "$OUT/tests/extra-notime32.cpio"
fi

log "public information"
P=$R/$TARGET-public-info.txt
# the root file system as it went into the images, and the kernel the images boot
ROOT=$(ls -d build_dir/target-*_ilp32_musl/root-$BOARD)
KIMAGE=$(ls build_dir/target-*_ilp32_musl/linux-${BOARD}_$SUBTARGET/linux-*/vmlinux)
{
	for f in etc/banner etc/openwrt_release etc/openwrt_version usr/lib/os-release \
		etc/apk/repositories.d/distfeeds.list; do
		echo "### /$f"; cat "$ROOT/$f" 2> /dev/null || echo "(missing)"
	done
	echo "### /etc/apk/keys"; ls "$ROOT/etc/apk/keys" 2> /dev/null || echo "(none)"
	echo "### kernel version string (uname -a, compiler)"
	# awk reads all of it: an early exit (grep -m1) would kill strings with SIGPIPE under pipefail
	strings "$KIMAGE" | awk '/^Linux version/ && !p { print; p = 1 }'
	for f in config feeds version; do echo "### $TARGET-$f.buildinfo"; cat "$R/$TARGET-$f.buildinfo"; done
} > "$P"
cat "$P"
# build host details that must not be published: VM and runner user/host names, home directories, private
# addresses, the author's non-public mail address, plus EXTRA_PATTERNS
PAT='ubuntu-VirtualBox|ubuntu@|/home/|runner@|fv-az|liviyifan@gmail|(^|[^0-9.])(192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+'
bad=0
grep -nE "$PAT" "$P" && bad=1
grep -rlE 'ubuntu-VirtualBox|/home/ubuntu|/home/runner|runner@fv-az|liviyifan@gmail' "$ROOT" 2> /dev/null && bad=1
# the upstream revision must not be shown as ours
grep -nF "$UPHASH" "$P" && bad=1
grep -rlF "$UPHASH" "$ROOT" "$R" 2> /dev/null && bad=1
if [ -n "${EXTRA_PATTERNS:-}" ]; then
	grep -nEf "$EXTRA_PATTERNS" "$P" && bad=1
	grep -rlEf "$EXTRA_PATTERNS" "$ROOT" "$R" 2> /dev/null && bad=1
fi
[ $bad = 0 ] || { echo "public information check FAILED" >&2; exit 1; }
log "public information check passed"
ls -l "$R"
