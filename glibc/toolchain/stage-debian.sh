#!/bin/bash
# Install trees for the debian session's ILP32 packages from the Debian-based toolchain
# (build-debian.sh, ../debian/build-debian.sh): one / tree per package under $STAGE/<package>/,
# plus MANIFEST and Debian's copyright and changelog files under $STAGE/doc/.
#   stage-debian.sh
#
#   libc6-ilp32           usr/lib/ld-linux-aarch64_ilp32.so.1, usr/libilp32/*.so* (glibc's slibdir),
#                         usr/libilp32/gconv/ (modules and gconv-modules*)
#   libc6-dev-ilp32       glibc headers in usr/aarch64-linux-gnu_ilp32/include, usr/libilp32/*.o *.a,
#                         dev links to the runtime sonames, linker scripts with /usr/libilp32 paths
#   linux-libc-dev-ilp32  the kernel UAPI headers (headers_install of $KCOMMIT) in
#                         usr/aarch64-linux-gnu_ilp32/include
#   libgcc-s1-ilp32 libstdc++6-ilp32 libatomic1-ilp32 libgomp1-ilp32   usr/libilp32/<soname> + library
# The split is the one of ilp32-issues/d13-gcc/build.sh (do_stage), so no file moves between packages.
# The compiler trees (binutils, gcc, g++) need the Canadian cross for the board (not here).
# Files are not stripped (debian's packaging strips them).
set -euo pipefail
IT=$(realpath "$(dirname "$(realpath "$0")")/../..")	# test-ilp32
TOP=${DEB_TC_WORK:-$HOME/work/build/deb-toolchain}
TC=${TC:-$TOP/out}
T=aarch64-linux-gnu_ilp32
TS=$TC/$T/sysroot
GCCLIB=$TC/$T/libilp32
STAGE=${STAGE:-$TOP/stage}
GLIBC_W=${DEB_WORK:-$HOME/work/debian-glibc}
GCC_SRC=${GCC_SRC:-$HOME/work/debian-gcc/gcc-14.2.0}
GCC_PKG=${GCC_PKG:-$HOME/work/debian-gcc/pkg}
BU_SRC=$TOP/debsrc/binutils
KTREE=$GLIBC_W/linux		# detached worktree of linux-ilp32 at KCOMMIT (glibc's kheaders step)
KCOMMIT=64b6f40074
HDR=usr/$T/include
V_GLIBC=2.41-12+deb13u4+ilp32a64.1
V_GCC=14.2.0-19+ilp32a64.1
V_BU=2.44-3+ilp32a64.1
V_LINUX=6.12.114-1+ilp32a64.2
RE=$TC/bin/$T-readelf

[ "$(git -C "$KTREE" rev-parse --short=10 HEAD)" = $KCOMMIT ] || { echo "$KTREE is not at $KCOMMIT"; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/doc"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# kernel UAPI headers: the file list of $KCOMMIT, each identical to the sysroot's
make -s -C "$KTREE" O="$W/kobj" ARCH=arm64 INSTALL_HDR_PATH="$W/kout" headers_install
(cd "$W/kout/include" && find . -type f | sort) > "$W/kernel-files.txt"
(cd "$W/kout/include" && while read -r f; do cmp "$f" "$TS/usr/include/$f"; done < "$W/kernel-files.txt")
echo "$(wc -l < "$W/kernel-files.txt") kernel headers, identical to the sysroot's"

P=$STAGE/libc6-ilp32
mkdir -p "$P/usr/lib" "$P/usr/libilp32/gconv"
cp -a "$TS/lib/ld-linux-aarch64_ilp32.so.1" "$P/usr/lib/"
cp -a "$TS"/libilp32/*.so* "$P/usr/libilp32/"
cp -a "$TS"/usr/libilp32/gconv/*.so "$TS"/usr/libilp32/gconv/gconv-modules* "$P/usr/libilp32/gconv/"

P=$STAGE/linux-libc-dev-ilp32
mkdir -p "$P/$HDR"
(cd "$TS/usr/include" && tar -cf - -T "$W/kernel-files.txt") | tar -C "$P/$HDR" -xf -

P=$STAGE/libc6-dev-ilp32
mkdir -p "$P/$HDR" "$P/usr/libilp32"
(cd "$TS/usr/include" && find . -type f | sort | comm -23 - "$W/kernel-files.txt" | tar -cf - -T -) |
	tar -C "$P/$HDR" -xf -
cp -a "$TS"/usr/libilp32/*.o "$TS"/usr/libilp32/*.a "$P/usr/libilp32/"
for f in "$TS"/usr/libilp32/*.so; do
	if [ -L "$f" ]; then		# dev link: to the runtime soname, in the same directory
		ln -s "$(basename "$(readlink "$f")")" "$P/usr/libilp32/$(basename "$f")"
	else				# linker script: the runtime libraries are in /usr/libilp32 on Debian
		sed 's|\([ (]\)/libilp32/|\1/usr/libilp32/|g' "$f" > "$P/usr/libilp32/$(basename "$f")"
	fi
done
if grep -l '[ (]/libilp32/' "$P"/usr/libilp32/*.so 2>/dev/null; then echo "linker script with /libilp32"; exit 1; fi

gcc_lib() { # <package> <soname>
	local P=$STAGE/$1 real
	real=$(readlink -f "$GCCLIB/$2")
	mkdir -p "$P/usr/libilp32"
	cp -a "$real" "$P/usr/libilp32/"
	[ "$(basename "$real")" = "$2" ] || ln -s "$(basename "$real")" "$P/usr/libilp32/$2"
}
gcc_lib libgcc-s1-ilp32 libgcc_s.so.1
gcc_lib libstdc++6-ilp32 libstdc++.so.6
gcc_lib libatomic1-ilp32 libatomic.so.1
gcc_lib libgomp1-ilp32 libgomp.so.1

# every ELF file is ELF32; every shared object has the BTI property
while read -r f; do
	"$RE" -h "$f" > /dev/null 2>&1 || continue		# linker scripts
	"$RE" -h "$f" | grep -q 'Class: *ELF32' || { echo "not ELF32: $f"; exit 1; }
	case $f in *.so*) "$RE" -n "$f" | grep -q 'AArch64 feature: BTI' || { echo "no BTI note: $f"; exit 1; } ;; esac
done < <(find "$STAGE" -type f \( -name '*.so*' -o -name '*.o' \))
if grep -rl -a /home/ "$STAGE"; then echo "build path in the files above"; exit 1; fi

cp "$GLIBC_W/src/debian/copyright" "$STAGE/doc/glibc.copyright"
cp "$GLIBC_W/src/debian/changelog" "$STAGE/doc/glibc.changelog"
cp "$GCC_PKG/debian/copyright" "$STAGE/doc/gcc-14.copyright"
cp "$GCC_PKG/debian/changelog" "$STAGE/doc/gcc-14.changelog"
cp "$BU_SRC/debian/copyright" "$STAGE/doc/binutils.copyright"
cp "$BU_SRC/debian/changelog" "$STAGE/doc/binutils.changelog"
cp "$GCC_SRC/COPYING.RUNTIME" "$STAGE/doc/gcc-COPYING.RUNTIME"

manifest() {
	local p
	echo "# AArch64 ILP32 runtime and libc development files from Debian 13 sources: install trees (<package>/)"
	echo "date: $(date -u +%F)   test-ilp32 $(git -C "$IT" log -1 --format=%h) glibc/toolchain/stage-debian.sh"
	echo
	echo "versions:"
	echo "  libc6-ilp32, libc6-dev-ilp32  $V_GLIBC"
	echo "  libgcc-s1-ilp32, libstdc++6-ilp32, libatomic1-ilp32, libgomp1-ilp32  $V_GCC"
	echo "  linux-libc-dev-ilp32  $V_LINUX"
	echo "  (built with binutils $V_BU)"
	echo
	echo "sources (Debian 13 trixie / trixie-security, .dsc sha256):"
	echo "  glibc_2.41-12+deb13u4.dsc  $(sha256sum "$GLIBC_W/glibc_2.41-12+deb13u4.dsc" | cut -d' ' -f1)"
	awk '{print "  " $4 "  " $6}' "$TOP/debsrc/SOURCES.txt"
	echo "  kernel UAPI headers: linux-ilp32 ilp32-6.12.y $KCOMMIT (= kernel $V_LINUX)"
	echo
	echo "patches:"
	echo "  glibc: Debian's 80 + test-ilp32 glibc/debian/patches/0001-0008"
	echo "         (= glibc-ilp32 ilp32-2.41 6a0b8e3665..be1ef73c3c)"
	echo "  gcc:   Debian's 83 for the cross build to arm64 on trixie (debian/rules patch) + test-ilp32"
	echo "         glibc/toolchain/patches/gcc-14.2.0-debian/0001-0002 (libgcc pac-ret unwind, libgcc ELF32"
	echo "         property notes) = debian-gcc gcc-14.2.0 branch ilp32 $(git -C "$GCC_SRC" rev-parse --short ilp32)"
	echo "  binutils: Debian's (dpkg-source), none added"
	echo
	echo "glibc configure: $(sed -n 's/^  \$ [^ ]*configure //p' "$GLIBC_W/build/glibc/config.log" | head -1 |
		sed "s|$TC|<toolchain>|g")"
	echo "glibc CFLAGS/ASFLAGS: -pipe -O2 -g (+ prefix maps); CC $T-gcc -mbranch-protection=bti -U_FILE_OFFSET_BITS -U_TIME_BITS"
	echo "gcc configure: $("$TC/bin/$T-gcc" -v 2>&1 | sed -n 's/^Configured with: [^ ]*configure //p' |
		sed "s|$TC|<toolchain>|g")"
	echo "gcc target libraries: CFLAGS_FOR_TARGET -g -O2 -mbranch-protection=bti (+ prefix maps)"
	echo
	echo "deviations from Debian's builds:"
	echo "  - cross built for the triplet aarch64-linux-gnu_ilp32 (dpkg has no ILP32 architecture); libraries in"
	echo "    /usr/libilp32, headers in /usr/$T/include, loader /usr/lib/ld-linux-aarch64_ilp32.so.1"
	echo "  - -mbranch-protection=bti instead of standard (GCC has no pac-ret for ILP32): glibc and gcc's target"
	echo "    libraries"
	echo "  - glibc: no --enable-memory-tagging (MTE tags are in pointer bits 56-59), no libmvec (--disable-mathvec,"
	echo "    not built for ILP32 anyway), --enable-kernel=3.2 raised to 5.10 (the ILP32 minimum), separate ILP32"
	echo "    headers (the port changes installed headers), only the ILP32 libraries (no arm64 pass)"
	echo "  - gcc: --disable-multiarch (gcc's aarch64 multiarch name is the LP64 triplet), --with-abi=ilp32"
	echo "    --with-multilib-list=ilp32 --disable-multilib, --enable-languages=c,c++, --disable-libsanitizer"
	echo "    (no ILP32 support); otherwise Debian's layout (gcc-cross/$T/14, -14 program suffix)"
	echo "  - prefix maps for build, toolchain and sysroot paths (no build path in the files)"
	echo "  - .dsc files pinned by sha256 (no Debian keyring for dpkg-source)"
	echo
	echo "tests (QEMU, kernel ilp32-6.12.y Image-ilp32-6.12.y-{noa32,pac}): glibc check-abi 15/15;"
	echo "  test-ilp32 run-glibc-test.sh 5/5, NOTIME32=1 4/4; libgcc pac-ret unwind (run-pac.sh) 9/9 on"
	echo "  -cpu max and cortex-a35; glibc PAC/BTI/dirty arguments (pac-run.sh) 7/7 on both"
	echo
	echo "doc/: Debian's copyright and changelog of glibc, gcc-14 and binutils; gcc-COPYING.RUNTIME"
	for p in "$STAGE"/*-ilp32; do
		echo
		echo "## $(basename "$p")"
		(cd "$p" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | LC_ALL=C sort | while read -r f; do
			if [ -L ".$f" ]; then echo "  $f -> $(readlink ".$f")"
			else echo "  $f $(sha256sum ".$f" | cut -c1-16)"; fi
		done)
	done
}
manifest > "$STAGE/MANIFEST"
for p in "$STAGE"/*-ilp32; do echo "$(basename "$p"): $(find "$p" \( -type f -o -type l \) | wc -l) files"; done
