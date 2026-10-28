#!/bin/bash
# glibc for the AArch64 ILP32 Debian packages (libc6-ilp32, libc6-dev-ilp32): Debian's glibc source package
# 2.41-12+deb13u4 with all of Debian's patches plus the ILP32 port (patches/), cross built for
# aarch64-linux-gnu_ilp32 with the configure options and flags of Debian's arm64 build (debian/rules,
# debian/rules.d/build.mk, debian/sysdeps/arm64.mk). The deviations from Debian's build are in MANIFEST.
#
#   build-debian.sh [steps...]      steps: source kheaders configure build install (default all, in order)
#   TC=<toolchain prefix>           cross gcc and binutils for aarch64-linux-gnu_ilp32
#                                   (default ~/work/build/deb-toolchain/out); glibc goes into its sysroot
#   SYSROOT=<directory>             where kheaders and install put their files instead (default
#                                   $TC/aarch64-linux-gnu_ilp32/sysroot)
#   KHEADERS=<directory>            kernel UAPI headers for configure --with-headers (default
#                                   $SYSROOT/usr/include, where the kheaders step installs them)
#   DEB_WORK=<work directory>       .dsc and orig tarball, source, build (default ~/work/debian-glibc)
#   KREPO=<linux-ilp32 clone>       kernel for the UAPI headers (default ~/work/linux-ilp32), used at KCOMMIT
#   J=<jobs>                        parallel make jobs (default 2)
# Each step leaves a stamp file (build/.<step>) and is skipped when re-run; delete it to redo a step.
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
T=aarch64-linux-gnu_ilp32
TC=${TC:-$HOME/work/build/deb-toolchain/out}
SYSROOT=${SYSROOT:-$TC/$T/sysroot}
KHEADERS=${KHEADERS:-$SYSROOT/usr/include}
W=${DEB_WORK:-$HOME/work/debian-glibc}
KREPO=${KREPO:-$HOME/work/linux-ilp32}
J=${J:-2}

# The Debian source package and the kernel commit of the ILP32 packages (6.12.114-1+ilp32a64.2)
DEB_VERSION=2.41-12+deb13u4
DSC=glibc_$DEB_VERSION.dsc
DSC_SHA256=0915324aa646bb99abfaa9aa6ecb734b30babd28454a3e51f3152912370fbd3e
MIRROR=https://deb.debian.org/debian/pool/main/g/glibc
KCOMMIT=64b6f40074
VERSION=$DEB_VERSION+ilp32a64.2

SRC=$W/src
B=$W/build
LOGS=$W/logs
mkdir -p "$W" "$B" "$LOGS"
export PATH=$TC/bin:$PATH

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
step() { # <name> <function>: run once, output to logs/<name>.log
	if [ -f "$B/.$1" ]; then log "$1: done before, skipped"; return; fi
	log "$1 ($(date +%H:%M))"
	# set -e does not work in a subshell that is part of a condition, also not left of ||, so run it
	# as a plain command with errexit off here and check its status
	local rc
	set +e
	( set -e; "$2" ) > "$LOGS/$1.log" 2>&1
	rc=$?
	set -e
	if [ $rc -ne 0 ]; then echo "FAILED: $1, see $LOGS/$1.log"; tail -30 "$LOGS/$1.log"; exit 1; fi
	touch "$B/.$1"
}

do_source() {
	cd "$W"
	[ -f "$DSC" ] || wget -nv "$MIRROR/$DSC"
	echo "$DSC_SHA256  $DSC" | sha256sum -c
	for f in $(awk '/^Files:/{f=1; next} /^[^ ]/{f=0} f{print $3}' "$DSC"); do
		[ -f "$f" ] || wget -nv "$MIRROR/$f"
	done
	# dpkg-source checks the files against the checksums of the .dsc and applies Debian's patches
	rm -rf "$SRC"
	dpkg-source --no-check -x "$DSC" "$SRC"
	cd "$SRC"
	for p in "$R"/patches/*.patch; do
		echo "patch $(basename "$p")"
		patch -p1 --batch --no-backup-if-mismatch < "$p"
	done
}

do_kheaders() {
	# a detached work tree at the packages' commit; the kernel session's trees are not touched
	[ -d "$W/linux" ] || git -C "$KREPO" worktree add --detach "$W/linux" "$KCOMMIT"
	[ "$(git -C "$W/linux" rev-parse --short=10 HEAD)" = "$KCOMMIT" ]
	rm -rf "$B/kheaders"
	make -C "$W/linux" O="$B/kheaders" ARCH=arm64 INSTALL_HDR_PATH="$SYSROOT/usr" headers_install
	test -f "$SYSROOT/usr/include/asm/unistd_ilp32.h"
}

# Debian's HOST_CFLAGS (-pipe -O2 -g -fdebug-prefix-map=<source>=.), used for C and assembly as in Debian's
# configparms, plus the other build paths mapped (MANIFEST)
HOST_CFLAGS="-pipe -O2 -g"
for m in "$SRC=." "$B/glibc=build" "$TC=/usr" "$SYSROOT="; do	# the last matching map wins
	HOST_CFLAGS="$HOST_CFLAGS -fdebug-prefix-map=$m -ffile-prefix-map=$m"
done

do_configure() {
	rm -rf "$B/glibc"; mkdir -p "$B/glibc"; cd "$B/glibc"
	# Debian's configparms (debian/rules.d/build.mk); the ILP32 directories as Debian's x32 flavour does
	cat > configparms <<-EOF
		BUILD_CC = gcc
		BUILD_CXX = g++
		CFLAGS = $HOST_CFLAGS
		ASFLAGS = $HOST_CFLAGS
		BUILD_CFLAGS = -O2 -g
		LDFLAGS =
		BASH := /bin/bash
		KSH := /bin/bash
		SHELL := /bin/bash
		LIBGD = no
		bindir = /usr/bin
		datadir = /usr/share
		complocaledir = /usr/lib/locale
		sysconfdir = /etc
		libexecdir = /usr/lib
		rootsbindir = /sbin
		includedir = /usr/include
		docdir = /usr/share/doc
		mandir = /usr/share/man
		sbindir = /usr/sbin
		vardbdir = /var/lib/misc
		libdir = /usr/libilp32
		slibdir = /libilp32
		rtlddir = /lib
	EOF
	# Debian's CC: <triplet>-gcc -mbranch-protection=standard; ILP32 has no return address signing in GCC
	CC="$T-gcc -mbranch-protection=bti -U_FILE_OFFSET_BITS -U_TIME_BITS" \
	CXX=$(if command -v $T-g++ > /dev/null; then echo "$T-g++ -mbranch-protection=bti -U_FILE_OFFSET_BITS -U_TIME_BITS"; else echo false; fi) \
	AUTOCONF=false MAKEINFO=: \
	"$SRC/configure" --host=$T --build="$(gcc -dumpmachine)" --prefix=/usr \
		--without-selinux --disable-crypt --enable-bind-now --enable-fortify-source \
		--enable-stackguard-randomization --enable-stack-protector=strong \
		--with-pkgversion="Debian GLIBC $VERSION" --with-bugurl="http://www.debian.org/Bugs/" \
		--with-timeoutfactor=25 --disable-mathvec \
		--with-headers="$KHEADERS" --enable-kernel=3.2 \
		--enable-multi-arch
	grep -E '^(config-machine|default-abi|slibdir|rtlddir|libdir|build-mathvec|enable-kernel) ' config.make || true
}

do_build() {
	cd "$B/glibc"
	make -j"$J"
}

do_install() {
	cd "$B/glibc"
	make install DESTDIR="$SYSROOT"
	# GCC looks for the start files in <sysroot>/usr/lib/../libilp32: usr/lib must exist for that path
	mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/lib"
}

STEPS=${*:-source kheaders configure build install}
for s in $STEPS; do
	step "$s" "do_$s"
done
log "done: $STEPS"
