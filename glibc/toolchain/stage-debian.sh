#!/bin/bash
# Install trees for the debian session's ILP32 packages from the Debian-based toolchain
# (build-debian.sh, ../debian/build-debian.sh): one / tree per package under $STAGE/<package>/,
# plus MANIFEST and Debian's copyright and changelog files under $STAGE/doc/.
#   PARTS=runtime|compiler STAGE=<new directory> stage-debian.sh
# A hand-off is a fixed snapshot: STAGE must not exist yet (e.g. stage-runtime-<date>, stage-native-<date>).
#
# PARTS=runtime:
#   libc6-ilp32           usr/lib/ld-linux-aarch64_ilp32.so.1, usr/libilp32/*.so* (glibc's slibdir),
#                         usr/libilp32/gconv/ (modules and gconv-modules*)
#   libc6-dev-ilp32       glibc headers in usr/aarch64-linux-gnu_ilp32/include, usr/libilp32/*.o *.a,
#                         dev links to the runtime sonames, linker scripts with /usr/libilp32 paths
#   linux-libc-dev-ilp32  the kernel UAPI headers (headers_install of $KCOMMIT) in
#                         usr/aarch64-linux-gnu_ilp32/include
#   libgcc-s1-ilp32 libstdc++6-ilp32 libatomic1-ilp32 libgomp1-ilp32   usr/libilp32/<soname> + library
# PARTS=compiler:
#   binutils-aarch64-linux-gnu-ilp32, gcc-14-aarch64-linux-gnu-ilp32, g++-14-aarch64-linux-gnu-ilp32
#                         the compiler for the board, from build-debian-native.sh's raw installs ($BRD)
# The split is the one of ilp32-issues/d13-gcc/build.sh (do_stage), so no file moves between packages.
# Target files are not stripped (debian's packaging strips them); the board's host binaries are.
set -euo pipefail
IT=$(realpath "$(dirname "$(realpath "$0")")/../..")	# test-ilp32
TOP=${DEB_TC_WORK:-$HOME/work/build/deb-toolchain}
TC=${TC:-$TOP/out}
T=aarch64-linux-gnu_ilp32
TS=$TC/$T/sysroot
GCCLIB=$TC/$T/libilp32
STAGE=${STAGE:?set STAGE to a new directory}
PARTS=${PARTS:?set PARTS to runtime or compiler}
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

case $PARTS in runtime|compiler) ;; *) echo "PARTS must be runtime or compiler"; exit 1 ;; esac
[ ! -e "$STAGE" ] || { echo "$STAGE exists: a hand-off is not changed afterwards, use a new directory"; exit 1; }
mkdir -p "$STAGE/doc"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

if [ "$PARTS" = runtime ]; then
[ "$(git -C "$KTREE" rev-parse --short=10 HEAD)" = $KCOMMIT ] || { echo "$KTREE is not at $KCOMMIT"; exit 1; }
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
fi

# every target ELF file is ELF32; every target shared object has the BTI property
while read -r f; do
	"$RE" -h "$f" > /dev/null 2>&1 || continue		# linker scripts
	# (output into a variable first: "cmd | grep -q" fails under pipefail when grep exits early)
	o=$("$RE" -h "$f")
	grep -q 'Class: *ELF32' <<< "$o" || { echo "not ELF32: $f"; exit 1; }
	case $f in *.so*) o=$("$RE" -n "$f"); grep -q 'AArch64 feature: BTI' <<< "$o" || { echo "no BTI note: $f"; exit 1; } ;; esac
done < <(find "$STAGE" -type f \( -name '*.so*' -o -name '*.o' \))

# The compiler for the board (build-debian-native.sh, built on an arm64 board; raw installs copied
# to $BRD): host side from its raw installs, target side unchanged from the x86-hosted toolchain.
# Names with -14 only (the unversioned links are made by the meta packages gcc-/g++-aarch64-linux-gnu-ilp32).
BRD=${BRD:-$TOP/native}
GD=lib/gcc-cross/$T/14 GX=libexec/gcc-cross/$T/14
if [ "$PARTS" = compiler ]; then
	[ -d "$BRD/raw-binutils" ] && [ -d "$BRD/raw-gcc" ] || { echo "no raw installs in $BRD"; exit 1; }
	R=$BRD/raw-binutils/usr
	P=$STAGE/binutils-aarch64-linux-gnu-ilp32
	mkdir -p "$P/usr/bin" "$P/usr/$T" "$P/usr/lib/$T"
	cp -a "$R"/bin/$T-* "$P/usr/bin/"
	cp -a "$R/$T/bin" "$P/usr/$T/"
	# ld's scripts in its libdir, /usr/lib/<triplet> (as Debian's cross binutils); not bfd-plugins
	# (libdep, static only with --disable-shared)
	cp -a "$R/lib/$T/ldscripts" "$P/usr/lib/$T/"
	o=$(strings -a "$P/usr/bin/$T-ld")
	grep -qx "/usr/lib/$T" <<< "$o" || { echo "ld: SCRIPTDIR is not /usr/lib/$T"; exit 1; }

	R=$BRD/raw-gcc/usr
	P=$STAGE/gcc-14-aarch64-linux-gnu-ilp32
	X=$STAGE/g++-14-aarch64-linux-gnu-ilp32
	mkdir -p "$P/usr/bin" "$X/usr/bin" "$P/usr/$GX" "$X/usr/$GX" "$P/usr/$GD"
	for f in gcc cpp gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool lto-dump; do
		cp -a "$R/bin/$T-$f-14" "$P/usr/bin/"
	done
	cp -a "$R/bin/$T-g++-14" "$X/usr/bin/"
	for f in cc1 collect2 lto1 lto-wrapper liblto_plugin.so; do cp -a "$R/$GX/$f" "$P/usr/$GX/"; done
	for f in cc1plus g++-mapper-server; do cp -a "$R/$GX/$f" "$X/usr/$GX/"; done
	# gcc's headers plus those the target libraries install there (unwind.h, omp.h, ...): the
	# x86-hosted toolchain's directory, after checking that every header of the board build is in it
	(cd "$R/$GD/include" && find . -type f | while read -r f; do cmp "$f" "$TC/$GD/include/$f"; done)
	cp -a "$TC/$GD/include" "$TC/$GD/include-fixed" "$P/usr/$GD/"
	# not libssp's headers: libssp is not packaged (glibc provides the stack protector)
	rm -rf "$P/usr/$GD/include/ssp"
	for f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o crtfastmath.o libgcc.a libgcc_eh.a libgcov.a; do
		cp -a "$TC/$GD/$f" "$P/usr/$GD/"
	done
	# fixincludes names the original header in a comment: the toolchain's sysroot there, the installed
	# system's header directory here (comment only)
	grep -rl "$TS/usr/include/" "$P/usr/$GD/include-fixed" | xargs -r sed -i "s|$TS/usr/include/|/$HDR/|g"
	# the target libraries' development files: static libraries, spec file, linker script and links to
	# the runtime libraries in /usr/libilp32, in gcc's library directory as in Debian's cross gcc
	# packages (libgcc-14-dev-<arch>-cross, libstdc++-14-dev-<arch>-cross), not in the tooldir:
	# gcc reaches <tooldir>/libilp32 only as <tooldir>/lib/../libilp32, which needs <tooldir>/lib
	for f in libgcc_s.so libatomic.a libgomp.a libgomp.spec; do cp -a "$GCCLIB/$f" "$P/usr/$GD/"; done
	ln -s /usr/libilp32/libatomic.so.1 "$P/usr/$GD/libatomic.so"
	ln -s /usr/libilp32/libgomp.so.1 "$P/usr/$GD/libgomp.so"
	mkdir -p "$X/usr/$GD" "$X/usr/$T/include/c++"
	for f in libstdc++.a libsupc++.a libstdc++fs.a libstdc++exp.a; do cp -a "$GCCLIB/$f" "$X/usr/$GD/"; done
	ln -s /usr/libilp32/libstdc++.so.6 "$X/usr/$GD/libstdc++.so"
	cp -a "$TC/$T/include/c++/14" "$X/usr/$T/include/c++/"
	find "$STAGE" -name '*.la' -delete

	# host binaries: ELF64 arm64 for Debian 13 (glibc <= 2.41), and the libraries they need
	HOSTINFO=$W/hostinfo
	maxv="" needed=""
	while read -r f; do
		o=$(file -b "$f"); grep -q 'ELF 64-bit LSB.*ARM aarch64' <<< "$o" || continue
		grep -q ', stripped' <<< "$o" || { echo "not stripped: $f"; exit 1; }
		i=$("$RE" -l "$f" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p')
		case $f in *.so) ;; *) [ "$i" = /lib/ld-linux-aarch64.so.1 ] || { echo "$f: interpreter '$i'"; exit 1; } ;; esac
		v=$("$RE" --dyn-syms -W "$f" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
		maxv=$(printf '%s\n%s\n' "$maxv" "$v" | sort -V | tail -1)
		needed="$needed $("$RE" -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	done < <(find "$STAGE"/binutils-* "$STAGE"/gcc-14-* "$STAGE"/g++-14-* -type f)
	[ "$(printf '%s\n%s\n' "$maxv" GLIBC_2.41 | sort -V | tail -1)" = GLIBC_2.41 ] || { echo "host binaries need $maxv"; exit 1; }
	{ echo "highest GLIBC symbol version: $maxv"
	  echo "NEEDED: $(echo $needed | tr ' ' '\n' | sort -u | tr '\n' ' ')"; } > "$HOSTINFO"
	cat "$HOSTINFO"
	for f in "$STAGE"/gcc-14-*/usr/bin/* "$STAGE"/g++-14-*/usr/bin/* "$STAGE"/gcc-14-*/usr/$GX/* "$STAGE"/g++-14-*/usr/$GX/* \
		"$STAGE"/binutils-*/usr/bin/*; do
		if grep -qaF -e --with-build-sysroot -e /home/ -e /srv/ "$f"; then echo "build path in $f"; exit 1; fi
	done
fi
if grep -rl -a -e /home/ -e ubuntu-VirtualBox -e Ubuntu "$STAGE"; then echo "build machine strings in the files above"; exit 1; fi

cp "$GLIBC_W/src/debian/copyright" "$STAGE/doc/glibc.copyright"
cp "$GLIBC_W/src/debian/changelog" "$STAGE/doc/glibc.changelog"
cp "$GCC_PKG/debian/copyright" "$STAGE/doc/gcc-14.copyright"
cp "$GCC_PKG/debian/changelog" "$STAGE/doc/gcc-14.changelog"
cp "$BU_SRC/debian/copyright" "$STAGE/doc/binutils.copyright"
cp "$BU_SRC/debian/changelog" "$STAGE/doc/binutils.changelog"
cp "$GCC_SRC/COPYING.RUNTIME" "$STAGE/doc/gcc-COPYING.RUNTIME"

manifest() {
	local p
	if [ "$PARTS" = runtime ]; then
		echo "# AArch64 ILP32 runtime and libc development files from Debian 13 sources: install trees (<package>/)"
	else
		echo "# AArch64 ILP32 compiler for Debian 13 arm64 from Debian 13 sources: install trees (<package>/)"
	fi
	echo "date: $(date -u +%F)   test-ilp32 $(git -C "$IT" log -1 --format=%h) glibc/toolchain/stage-debian.sh PARTS=$PARTS"
	echo
	echo "versions:"
	if [ "$PARTS" = runtime ]; then
		echo "  libc6-ilp32, libc6-dev-ilp32  $V_GLIBC"
		echo "  libgcc-s1-ilp32, libstdc++6-ilp32, libatomic1-ilp32, libgomp1-ilp32  $V_GCC"
		echo "  linux-libc-dev-ilp32  $V_LINUX"
		echo "  (built with binutils $V_BU)"
	else
		echo "  binutils-aarch64-linux-gnu-ilp32  $V_BU"
		echo "  gcc-14-aarch64-linux-gnu-ilp32, g++-14-aarch64-linux-gnu-ilp32  $V_GCC"
		echo "  (target files from the runtime hand-off's toolchain: glibc $V_GLIBC, kernel UAPI $V_LINUX)"
	fi
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
		sed -e "s|$TC|<toolchain>|g" -e 's/ -f\(file\|debug\)-prefix-map=[^ '"'"']*//g' \
			-e "s/\(FLAGS_FOR_TARGET=[^']*\)'/\1 (+ prefix maps)'/g")"
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
	if [ -n "${HOSTINFO:-}" ]; then
		echo
		echo "compiler for the board (binutils, gcc-14, g++-14 trees): test-ilp32 glibc/toolchain/build-debian-native.sh"
		echo "  built natively on an arm64 Debian 13 board (build = host = aarch64-linux-gnu, Debian's gcc 14.2.0-19),"
		echo "  target aarch64-linux-gnu_ilp32, linked against Debian 13's arm64 gmp, mpfr, mpc, isl, zlib, zstd, jansson;"
		echo "  binutils from apt-get source binutils=2.44-3 on the board, gcc from the same tree as the x86-hosted toolchain;"
		echo "  host flags -g -O2, -Wl,-z,relro (Debian's for cross compilers); host binaries stripped"
		echo "  prefix /usr, sysroot /, headers /$HDR, libraries /usr/libilp32, gcc in /usr/lib/gcc-cross/$T/14"
		echo "  and /usr/libexec/gcc-cross/$T/14; only the -14 names (meta packages add the unversioned links);"
		echo "  the target libraries' dev files (lib*.a, libgomp.spec, libgcc_s.so script, lib*.so links to"
		echo "  /usr/libilp32) in /usr/lib/gcc-cross/$T/14 as Debian's cross gcc packages, no /usr/$T/libilp32"
		echo "  target files (crt*.o, libgcc*.a, libgcov.a, headers, libstdc++/libatomic/libgomp static libraries,"
		echo "  C++ headers) are the x86-hosted toolchain's, unchanged (fixincludes' path comments rewritten),"
		echo "  without include/ssp (libssp, libitm are built but not packaged)"
		echo "  binutils deviations: --disable-shared (static libbfd/libopcodes/libctf/libsframe, no collision"
		echo "  with Debian's libbinutils; so no bfd-plugins/libdep.so), --disable-gprofng (not packaged);"
		echo "  libdir /usr/lib/$T as Debian's cross binutils (ld scripts there); gcc --with-bugurl: the project's tracker"
		sed 's/^/  /' "$HOSTINFO"
		echo "gcc (board) configure: $(strings -a "$STAGE/gcc-14-aarch64-linux-gnu-ilp32/usr/bin/$T-gcc-14" | grep -m1 -- '--with-pkgversion')"
	fi
	echo
	echo "tests (QEMU, kernel ilp32-6.12.y Image-ilp32-6.12.y-{noa32,pac}): glibc check-abi 15/15;"
	echo "  test-ilp32 run-glibc-test.sh 5/5, NOTIME32=1 4/4; libgcc pac-ret unwind (run-pac.sh) 9/9 on"
	echo "  -cpu max and cortex-a35; glibc PAC/BTI/dirty arguments (pac-run.sh) 7/7 on both"
	if [ "$PARTS" = compiler ]; then
		echo "native build checks: the board build's target libraries (libgcc_s, libstdc++, libatomic, libgomp,"
		echo "  their static libraries, libgcc*.a, crt*.o) are identical to the x86-hosted toolchain's except debug"
		echo "  info and build-id; C++ and gcc headers identical. Testsuites on the board (libstdc++, libgomp, glibc"
		echo "  make check): run after this hand-off, results reported separately."
	fi
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
