#!/bin/bash
# AArch64 ILP32 cross toolchain from Debian 13 sources: binutils 2.44-3 and gcc-14 14.2.0-19 with
# Debian's patches and configure options (Debian's cross build to arm64, evaluated in a Debian 13
# chroot), plus the ILP32 changes listed below. glibc is ../debian/build-debian.sh.
#   build-debian.sh [step...]     (default: binutils gcc1; after glibc is installed: gcc2)
#
#   binutils  debsrc/binutils (dpkg-source -x of binutils_2.44-3.dsc)
#   gcc1      C only, no C library (stage 1, for glibc)
#   gcc2      C and C++ with libgcc_s, libstdc++, libatomic, libgomp (glibc in the sysroot)
#
#   target    aarch64-linux-gnu_ilp32 (default -mabi=ilp32), prefix $TC, sysroot
#             $TC/aarch64-linux-gnu_ilp32/sysroot (usr/include, libilp32, usr/libilp32)
#   gcc       ~/work/debian-gcc/gcc-14.2.0 branch ilp32: Debian's 83 patches for the cross
#             build to arm64 on trixie, autoconf2.69, gcc/distro-defaults.h, the libgcc PAC fix
#
# Deviations from Debian's cross build (each also in the MANIFEST):
#   --disable-multiarch          gcc's aarch64 MULTIARCH_DIRNAME is the LP64 triplet also for ILP32
#   --with-abi=ilp32 --with-multilib-list=ilp32 --disable-multilib   ILP32 only
#   -mbranch-protection=bti      for the target libraries instead of standard: GCC has no ILP32 pac-ret
#   --enable-languages=c,c++     only C and C++ are packaged
#   --disable-libsanitizer       no ILP32 support in libsanitizer
#   own prefix and --with-sysroot, prefix maps for build paths (as glibc)
# Each step leaves a stamp ($B/.<step>) and is skipped when re-run; delete it to redo a step.
set -euo pipefail
TOP=${DEB_TC_WORK:-$HOME/work/build/deb-toolchain}
TC=${TC:-$TOP/out}
T=aarch64-linux-gnu_ilp32
SYSROOT=$TC/$T/sysroot
BU_SRC=$TOP/debsrc/binutils
GCC_SRC=${GCC_SRC:-$HOME/work/debian-gcc/gcc-14.2.0}
GCC_BRANCH=ilp32
B=$TOP/build
LOGS=$TOP/logs
J=${J:-2}          # at most -j2 on this VM (shared with other builds)
GCC_PKGVERSION="Debian 14.2.0-19+ilp32a64.1"
BU_PKGVERSION="GNU Binutils for Debian"
export PATH=$TC/bin:$PATH
export LANG=C.UTF-8
mkdir -p "$B" "$LOGS" "$SYSROOT/usr/include"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
step() { # <name> <function>: run once, output to logs/<name>.log
	if [ -f "$B/.$1" ]; then log "$1: done before, skipped"; return; fi
	log "$1 ($(date +%H:%M))"
	# set -e does not work in a subshell left of || or in a condition: run it as a plain command
	local rc
	set +e
	( set -e; "$2" ) > "$LOGS/$1.log" 2>&1
	rc=$?
	set -e
	if [ $rc -ne 0 ]; then echo "FAILED: $1, see $LOGS/$1.log"; tail -30 "$LOGS/$1.log"; exit 1; fi
	touch "$B/.$1"
}

# Host programs: Debian's CFLAGS/LDFLAGS for the cross build (dpkg-buildflags on Debian 13, without
# hardening, as gcc's rules2 and binutils' rules use them).
HOST_ENV=(CFLAGS="-g -O2" CXXFLAGS="-g -O2" LDFLAGS="-Wl,-z,relro")

# Target libraries: Debian's -g -O2 + CFLAGS_FOR_TARGET (-mbranch-protection=standard -> bti), build
# paths mapped as in glibc (-ffile-prefix-map and -fdebug-prefix-map, the latter reaches .S files).
TARGET_FLAGS="-g -O2 -mbranch-protection=bti"
for m in "$GCC_SRC=/usr/src/gcc-14" "$B=/usr/src/gcc-14/build" "$TC=/usr" "$SYSROOT="; do
	TARGET_FLAGS="$TARGET_FLAGS -ffile-prefix-map=$m -fdebug-prefix-map=$m"
done

check_gcc_src() {
	[ "$(git -C "$GCC_SRC" symbolic-ref --short HEAD)" = $GCC_BRANCH ] || { echo "$GCC_SRC: not on $GCC_BRANCH"; return 1; }
	[ -z "$(git -C "$GCC_SRC" status --porcelain)" ] || { echo "$GCC_SRC: not clean"; return 1; }
	echo "gcc source $(git -C "$GCC_SRC" log -1 --format='%h %s')"
}

# Debian's CROSS_CONFARGS (binutils 2.44-3 debian/rules) with our prefix and sysroot.
do_binutils() {
	rm -rf "$B/binutils"; mkdir -p "$B/binutils"; cd "$B/binutils"
	env "${HOST_ENV[@]}" CFLAGS="-g -O2 -ffile-prefix-map=$BU_SRC=." "$BU_SRC/configure" \
		--disable-silent-rules --enable-obsolete --enable-plugins --enable-threads --enable-jansson \
		--enable-default-hash-style=gnu --enable-deterministic-archives \
		--disable-compressed-debug-sections --enable-new-dtags --disable-x86-used-note \
		--disable-default-execstack --prefix="$TC" --enable-shared --with-system-zlib \
		--with-pkgversion="$BU_PKGVERSION" --disable-werror --enable-initfini-array \
		--enable-ld=default --disable-gold --with-sysroot="$SYSROOT" --target=$T
	make -j"$J"
	make install
	"$TC/bin/$T-ld" --version | head -1
}

# Options of Debian's gcc-14 rules2 for the cross build that apply to both stages.
GCC_COMMON=(--target=$T --prefix="$TC" --libexecdir="$TC/libexec" --with-sysroot="$SYSROOT"
	--with-pkgversion="$GCC_PKGVERSION" --with-bugurl=file:///usr/share/doc/gcc-14/README.Bugs
	--with-gcc-major-version-only --program-prefix=$T- --program-suffix=-14 --enable-linker-build-id
	--enable-default-pie --with-system-zlib --without-target-system-zlib --enable-fix-cortex-a53-843419
	--disable-werror --enable-checking=release
	--with-abi=ilp32 --with-multilib-list=ilp32 --disable-multilib --disable-multiarch)

# Debian installs the unsuffixed names in gcc-aarch64-linux-gnu and friends as links to the -14 ones.
link_unsuffixed() {
	local f
	for f in "$TC"/bin/$T-*-14; do
		ln -sfn "$(basename "$f")" "${f%-14}"
	done
}

do_gcc1() {
	check_gcc_src
	rm -rf "$B/gcc1"; mkdir -p "$B/gcc1"; cd "$B/gcc1"
	env "${HOST_ENV[@]}" "$GCC_SRC/configure" "${GCC_COMMON[@]}" \
		--enable-languages=c --without-headers --with-newlib --disable-shared --disable-threads \
		--disable-nls --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp \
		--disable-libsanitizer --disable-libitm --disable-libstdcxx --disable-decimal-float \
		CFLAGS_FOR_TARGET="$TARGET_FLAGS" CXXFLAGS_FOR_TARGET="$TARGET_FLAGS"
	make -j"$J" all-gcc all-target-libgcc
	make install-gcc install-target-libgcc
	link_unsuffixed
	"$TC/bin/$T-gcc" -v 2>&1 | tail -1
	echo "multi-os-directory $("$TC/bin/$T-gcc" -print-multi-os-directory)"
}

do_gcc2() {
	check_gcc_src
	test -f "$SYSROOT/libilp32/libc.so.6" || { echo "glibc is not installed in $SYSROOT"; return 1; }
	rm -rf "$B/gcc2"; mkdir -p "$B/gcc2"; cd "$B/gcc2"
	env "${HOST_ENV[@]}" "$GCC_SRC/configure" "${GCC_COMMON[@]}" \
		--enable-languages=c,c++ --enable-shared --without-included-gettext --enable-threads=posix \
		--enable-nls --enable-clocale=gnu --enable-libstdcxx-debug --enable-libstdcxx-time=yes \
		--with-default-libstdcxx-abi=new --enable-libstdcxx-backtrace --enable-gnu-unique-object \
		--disable-libquadmath --disable-libquadmath-support --enable-plugin --disable-libsanitizer \
		CFLAGS_FOR_TARGET="$TARGET_FLAGS" CXXFLAGS_FOR_TARGET="$TARGET_FLAGS"
	make -j"$J"
	make install
	link_unsuffixed
	"$TC/bin/$T-g++" -v 2>&1 | tail -1
	ls "$TC/$T"/libilp32 2>/dev/null | grep -E '^lib(gcc_s|stdc\+\+|atomic|gomp)\.so' || true
}

[ $# -gt 0 ] || set -- binutils gcc1
for s in "$@"; do
	case $s in
	binutils|gcc1|gcc2) step $s do_$s ;;
	*) echo "unknown step $s"; exit 1 ;;
	esac
done
log "done: $*"
