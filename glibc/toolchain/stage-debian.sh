#!/bin/bash
# Install trees for the debian session's ILP32 packages from the Debian-based toolchain
# (build-debian.sh, ../debian/build-debian.sh): one / tree per package under $STAGE/<package>/,
# plus MANIFEST and Debian's copyright and changelog files under $STAGE/doc/.
#   PARTS=runtime|compiler|glibc STAGE=<new directory> stage-debian.sh
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
# PARTS=glibc:
#   libc6-ilp32, libc6-dev-ilp32 as for runtime, from the release build of ../debian/check-debian-clean.sh
#                         (a fresh clean chroot on an arm64 Debian 13 board, its testsuite run included):
#                         GLIBC_REL=<its output directory> with raw-glibc/, tests.sum, dpkg-l.txt, ...
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
PARTS=${PARTS:?set PARTS to runtime, compiler or glibc}
GLIBC_W=${DEB_WORK:-$HOME/work/debian-glibc}
GCC_SRC=${GCC_SRC:-$HOME/work/debian-gcc/gcc-14.2.0}
GCC_PKG=${GCC_PKG:-$HOME/work/debian-gcc/pkg}
BU_SRC=$TOP/debsrc/binutils
KTREE=$GLIBC_W/linux		# detached worktree of linux-ilp32 at KCOMMIT (glibc's kheaders step)
KCOMMIT=64b6f40074
HDR=usr/$T/include
V_GLIBC=2.41-12+deb13u4+ilp32a64.1	# runtime, compiler: the released glibc
V_GLIBC_NEW=2.41-12+deb13u4+ilp32a64.2	# glibc: the new build (TLS descriptor fix)
V_GCC=14.2.0-19+ilp32a64.1		# the GCC runtime packages
V_GCC_CC=14.2.0-19+ilp32a64.2		# the compiler packages (omp.h fixed); runtime unchanged
V_BU=2.44-3+ilp32a64.1
V_LINUX=6.12.114-1+ilp32a64.2
case $PARTS in runtime|compiler|glibc) ;; *) echo "PARTS must be runtime, compiler or glibc"; exit 1 ;; esac
# the toolchain must be the build of the packages' version: gcc -v shows it (--with-pkgversion); for
# glibc only its binutils are used (the glibc build is the board's)
if [ "$PARTS" != glibc ]; then
	o=$("$TC/bin/$T-gcc" -v 2>&1)
	case $PARTS in
	runtime) want=$V_GCC ;;
	compiler) want=$V_GCC_CC ;;
	esac
	grep -qF "(Debian $want)" <<< "$o" || { echo "$TC is not the gcc $want build"; exit 1; }
fi
RE=$TC/bin/$T-readelf
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

if [ "$PARTS" = glibc ]; then
	GR=${GLIBC_REL:?set GLIBC_REL to the output directory of check-debian-clean.sh}
	RG=$GR/raw-glibc
	for f in raw-glibc tests.sum dpkg-l.txt compare.txt; do
		[ -e "$GR/$f" ] || { echo "no $f in $GR"; exit 1; }
	done
	o=$(strings -a "$RG/libilp32/libc.so.6")
	grep -qF "(Debian GLIBC $V_GLIBC_NEW)" <<< "$o" || { echo "$RG is not the glibc $V_GLIBC_NEW build"; exit 1; }
	# glibc installs no kernel headers (they come from linux-libc-dev-ilp32)
	for d in linux asm asm-generic; do [ ! -e "$RG/usr/include/$d" ] || { echo "kernel headers in $RG"; exit 1; }; done
	P=$STAGE/libc6-ilp32
	mkdir -p "$P/usr/lib" "$P/usr/libilp32/gconv"
	cp -a "$RG/lib/ld-linux-aarch64_ilp32.so.1" "$P/usr/lib/"
	cp -a "$RG"/libilp32/*.so* "$P/usr/libilp32/"
	cp -a "$RG"/usr/libilp32/gconv/*.so "$RG"/usr/libilp32/gconv/gconv-modules* "$P/usr/libilp32/gconv/"
	P=$STAGE/libc6-dev-ilp32
	mkdir -p "$P/$HDR" "$P/usr/libilp32"
	cp -a "$RG/usr/include/." "$P/$HDR/"
	cp -a "$RG"/usr/libilp32/*.o "$RG"/usr/libilp32/*.a "$P/usr/libilp32/"
	for f in "$RG"/usr/libilp32/*.so; do
		if [ -L "$f" ]; then
			ln -s "$(basename "$(readlink "$f")")" "$P/usr/libilp32/$(basename "$f")"
		else
			sed 's|\([ (]\)/libilp32/|\1/usr/libilp32/|g' "$f" > "$P/usr/libilp32/$(basename "$f")"
		fi
	done
	if grep -l '[ (]/libilp32/' "$P"/usr/libilp32/*.so 2>/dev/null; then echo "linker script with /libilp32"; exit 1; fi
	# against the released .1 trees: the same file lists and headers; the code differs only where the
	# patches since .1 changed it (and the known scheduling tie of the x86-hosted .1 build in inet_ntop)
	RT=${RUNTIME_STAGE:-$TOP/stage-runtime-20261027}
	OC=$TC/bin/$T-objcopy
	norm() { "$OC" --strip-all --remove-section=.comment --remove-section=.note.gnu.build-id \
		--remove-section=.gnu_debuglink "$1" "$2" 2> /dev/null; }
	CODECHECK=$W/codecheck
	for p in libc6-ilp32 libc6-dev-ilp32; do
		diff <(cd "$RT/$p" && find . | sort) <(cd "$STAGE/$p" && find . | sort) ||
			{ echo "$p: file list differs from the released $V_GLIBC"; exit 1; }
	done
	diff -r "$RT/libc6-dev-ilp32/$HDR" "$STAGE/libc6-dev-ilp32/$HDR" > /dev/null ||
		{ echo "headers differ from the released $V_GLIBC"; exit 1; }
	echo "  file lists and headers: identical to the released $V_GLIBC" >> "$CODECHECK"
	n=0 d=""
	while read -r f; do
		a=$RT/$f b=$STAGE/$f
		n=$((n+1))
		cmp -s "$a" "$b" && continue
		o=$(file -b "$b")
		case $o in
		ELF*) norm "$a" "$W/a" && norm "$b" "$W/b" && cmp -s "$W/a" "$W/b" && continue ;;
		"current ar archive"*)
			rm -rf "$W/xa" "$W/xb"; mkdir "$W/xa" "$W/xb"
			(cd "$W/xa" && ar x "$a"); (cd "$W/xb" && ar x "$b")
			m=""
			for x in $(ls "$W/xa"); do
				norm "$W/xa/$x" "$W/a"; norm "$W/xb/$x" "$W/b"; cmp -s "$W/a" "$W/b" || m="$m,$x"
			done
			[ -z "$m" ] && continue
			d="$d ${f}[${m#,}]"; continue ;;
		esac
		d="$d $f"
	done < <(cd "$RT" && find libc6-ilp32 libc6-dev-ilp32 -type f ! -path "*/$HDR/*" | sort)
	echo "  libraries and objects: $n compared with the released $V_GLIBC; code differs in:" >> "$CODECHECK"
	for x in $d; do echo "    $x" >> "$CODECHECK"; done
	cat "$CODECHECK"
fi

# every target ELF file is ELF32; every target shared object has the BTI property
while read -r f; do
	"$RE" -h "$f" > /dev/null 2>&1 || continue		# linker scripts
	# (output into a variable first: "cmd | grep -q" fails under pipefail when grep exits early)
	o=$("$RE" -h "$f")
	grep -q 'Class: *ELF32' <<< "$o" || { echo "not ELF32: $f"; exit 1; }
	case $f in *.so*) o=$("$RE" -n "$f"); grep -q 'AArch64 feature: BTI' <<< "$o" || { echo "no BTI note: $f"; exit 1; } ;; esac
done < <(find "$STAGE" -type f \( -name '*.so*' -o -name '*.o' \))
# no ELF64-layout (corrupt) property note in any target object, also inside the archives
while read -r f; do
	# (linker scripts such as libc.so are not ELF: skip them, but not a failing ELF file)
	o=$("$RE" -n "$f" 2>&1) || { "$RE" -h "$f" > /dev/null 2>&1 || continue; echo "readelf -n failed: $f"; exit 1; }
	if grep -q 'corrupt' <<< "$o"; then echo "corrupt note in $f:"; grep 'corrupt' <<< "$o" | head -3; exit 1; fi
done < <(find "$STAGE" -type f \( -name '*.so*' -o -name '*.o' -o -name '*.a' \) ! -path '*/usr/bin/*' ! -path '*/libexec/*')

# The compiler for the board: the release build of build-debian-clean.sh (a fresh clean chroot on an
# arm64 Debian 13 system; its output copied to $CLEAN), host and target side. binutils is released
# and unchanged, so not part of this hand-off. Names with -14 only (the meta packages add the
# unversioned links).
CLEAN=${CLEAN:-$TOP/clean}
GD=lib/gcc-cross/$T/14 GX=libexec/gcc-cross/$T/14
if [ "$PARTS" = compiler ]; then
	R=$CLEAN/raw-gcc/usr
	[ -d "$R" ] && [ -f "$CLEAN/dpkg-l.txt" ] && [ -f "$CLEAN/omp-check.txt" ] || { echo "no clean build in $CLEAN"; exit 1; }
	o=$(strings -a "$R/bin/$T-gcc-14")
	grep -qF "(Debian $V_GCC_CC)" <<< "$o" || { echo "$R is not the gcc $V_GCC_CC build"; exit 1; }
	P=$STAGE/gcc-14-aarch64-linux-gnu-ilp32
	X=$STAGE/g++-14-aarch64-linux-gnu-ilp32
	mkdir -p "$P/usr/bin" "$X/usr/bin" "$P/usr/$GX" "$X/usr/$GX" "$P/usr/$GD" "$X/usr/$GD" "$X/usr/$T/include/c++"
	for f in gcc cpp gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool lto-dump; do
		cp -a "$R/bin/$T-$f-14" "$P/usr/bin/"
	done
	cp -a "$R/bin/$T-g++-14" "$X/usr/bin/"
	for f in cc1 collect2 lto1 lto-wrapper liblto_plugin.so; do cp -a "$R/$GX/$f" "$P/usr/$GX/"; done
	for f in cc1plus g++-mapper-server; do cp -a "$R/$GX/$f" "$X/usr/$GX/"; done
	# gcc's headers (with those of the target libraries: unwind.h, omp.h, ...), fixed headers (built
	# from the installed libc6-dev-ilp32, so their comments name /usr/<triplet>/include), start files
	cp -a "$R/$GD/include" "$R/$GD/include-fixed" "$P/usr/$GD/"
	# not libssp's headers: libssp is not packaged (glibc provides the stack protector)
	rm -rf "$P/usr/$GD/include/ssp"
	for f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o crtfastmath.o libgcc.a libgcc_eh.a libgcov.a; do
		cp -a "$R/$GD/$f" "$P/usr/$GD/"
	done
	# the target libraries' development files: static libraries, spec file, linker script and links to
	# the runtime libraries in /usr/libilp32, in gcc's library directory as in Debian's cross gcc
	# packages (libgcc-14-dev-<arch>-cross, libstdc++-14-dev-<arch>-cross), not in the tooldir:
	# gcc reaches <tooldir>/libilp32 only as <tooldir>/lib/../libilp32, which needs <tooldir>/lib
	L=$R/$T/libilp32
	for f in libgcc_s.so libatomic.a libgomp.a libgomp.spec; do cp -a "$L/$f" "$P/usr/$GD/"; done
	ln -s /usr/libilp32/libatomic.so.1 "$P/usr/$GD/libatomic.so"
	ln -s /usr/libilp32/libgomp.so.1 "$P/usr/$GD/libgomp.so"
	for f in libstdc++.a libsupc++.a libstdc++fs.a libstdc++exp.a; do cp -a "$L/$f" "$X/usr/$GD/"; done
	ln -s /usr/libilp32/libstdc++.so.6 "$X/usr/$GD/libstdc++.so"
	cp -a "$R/$T/include/c++/14" "$X/usr/$T/include/c++/"
	find "$STAGE" -name '*.la' -delete

	# the target code is the released runtime's (.1, stage-runtime-20261027) and the x86-hosted
	# toolchain's: identical except debug info, build-id and .comment (the version string)
	RT=${RUNTIME_STAGE:-$TOP/stage-runtime-20261027}
	OC=$TC/bin/$T-objcopy
	samecode() { # <a> <b>
		"$OC" --strip-debug --remove-section=.note.gnu.build-id --remove-section=.comment "$1" "$W/a" 2>/dev/null
		"$OC" --strip-debug --remove-section=.note.gnu.build-id --remove-section=.comment "$2" "$W/b" 2>/dev/null
		cmp -s "$W/a" "$W/b"
	}
	CODECHECK=$W/codecheck
	for f in libgcc-s1-ilp32/usr/libilp32/libgcc_s.so.1 libstdc++6-ilp32/usr/libilp32/libstdc++.so.6.0.33 \
		libatomic1-ilp32/usr/libilp32/libatomic.so.1.2.0 libgomp1-ilp32/usr/libilp32/libgomp.so.1.0.0; do
		samecode "$RT/$f" "$L/$(basename "$f")" || { echo "code differs from the released runtime: $f"; exit 1; }
		echo "  $(basename "$f"): same code as the released runtime $V_GCC" >> "$CODECHECK"
	done
	for f in libatomic.a libgomp.a libstdc++.a libsupc++.a libstdc++fs.a libstdc++exp.a; do
		samecode "$TC/$T/libilp32/$f" "$L/$f" || { echo "code differs from the x86-hosted toolchain: $f"; exit 1; }
	done
	for f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o crtfastmath.o libgcc.a libgcc_eh.a libgcov.a; do
		samecode "$TC/$GD/$f" "$R/$GD/$f" || { echo "code differs from the x86-hosted toolchain: $f"; exit 1; }
	done
	echo "  static libraries and start files: same code as the x86-hosted toolchain's $V_GCC_CC build" >> "$CODECHECK"
	diff -r "$TC/$GD/include" "$R/$GD/include" > /dev/null || { echo "gcc headers differ from the x86-hosted toolchain"; exit 1; }
	diff -r "$TC/$T/include/c++/14" "$R/$T/include/c++/14" > /dev/null || { echo "C++ headers differ from the x86-hosted toolchain"; exit 1; }
	echo "  gcc and C++ headers: identical to the x86-hosted toolchain's" >> "$CODECHECK"
	cat "$CODECHECK"

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
	done < <(find "$STAGE"/gcc-14-* "$STAGE"/g++-14-* -type f)
	[ "$(printf '%s\n%s\n' "$maxv" GLIBC_2.41 | sort -V | tail -1)" = GLIBC_2.41 ] || { echo "host binaries need $maxv"; exit 1; }
	{ echo "highest GLIBC symbol version: $maxv"
	  echo "NEEDED: $(echo $needed | tr ' ' '\n' | sort -u | tr '\n' ' ')"; } > "$HOSTINFO"
	cat "$HOSTINFO"
	# no build path anywhere in the trees: the clean build's /build/src, /build/build, /build/raw-gcc
	# (its path maps give /usr/src/gcc-14/build/..., which is fine), the board's and the VM's paths
	if grep -rlaF -e /build/src/ -e /build/build/ -e /build/raw-gcc/ -e /srv/ -e /home/ \
		"$STAGE"/gcc-14-* "$STAGE"/g++-14-*; then echo "build path in the files above"; exit 1; fi
fi
if grep -rl -a -e /home/ -e ubuntu-VirtualBox -e Ubuntu "$STAGE"; then echo "build machine strings in the files above"; exit 1; fi

cp "$GLIBC_W/src/debian/copyright" "$STAGE/doc/glibc.copyright"
cp "$GLIBC_W/src/debian/changelog" "$STAGE/doc/glibc.changelog"
if [ "$PARTS" != glibc ]; then
	cp "$GCC_PKG/debian/copyright" "$STAGE/doc/gcc-14.copyright"
	cp "$GCC_PKG/debian/changelog" "$STAGE/doc/gcc-14.changelog"
	cp "$BU_SRC/debian/copyright" "$STAGE/doc/binutils.copyright"
	cp "$BU_SRC/debian/changelog" "$STAGE/doc/binutils.changelog"
	cp "$GCC_SRC/COPYING.RUNTIME" "$STAGE/doc/gcc-COPYING.RUNTIME"
fi

manifest_glibc() {
	local p
	echo "# AArch64 ILP32 glibc for Debian 13 from Debian 13 sources: install trees (<package>/)"
	echo "date: $(date -u +%F)   test-ilp32 $(git -C "$IT" log -1 --format=%h) glibc/toolchain/stage-debian.sh PARTS=glibc"
	echo
	echo "versions:"
	echo "  libc6-ilp32, libc6-dev-ilp32  $V_GLIBC_NEW"
	echo "  (the other packages are released and unchanged: linux-libc-dev-ilp32 $V_LINUX, the GCC runtime"
	echo "  $V_GCC, gcc-14/g++-14 $V_GCC_CC, binutils $V_BU)"
	echo
	echo "changes since $V_GLIBC:"
	echo "  - aarch64: return 64-bit TLS descriptor offsets for ILP32 (glibc-ilp32 2690bdac8f, patch 0009):"
	echo "    _dl_tlsdesc_dynamic and _dl_tlsdesc_undefweak computed the thread pointer offset in 32-bit"
	echo "    registers; compilers use it as a 64-bit value, so __thread variables of dlopen'ed libraries"
	echo "    with dynamic TLS below the thread pointer faulted"
	echo "  - aarch64: tst-auditmod26, tst-auditmod27 and tst-sme-signal build for ILP32 (c50cf3b9ed,"
	echo "    patch 0010; tests only)"
	echo
	echo "source: glibc_2.41-12+deb13u4.dsc  $(sha256sum "$GLIBC_W/glibc_2.41-12+deb13u4.dsc" | cut -d' ' -f1)"
	echo "patches: Debian's 80 + test-ilp32 glibc/debian/patches/0001-0010"
	echo "  (= glibc-ilp32 ilp32-2.41 6a0b8e3665..c50cf3b9ed)"
	echo "kernel UAPI headers: the released linux-libc-dev-ilp32 $V_LINUX (linux-ilp32 $KCOMMIT)"
	echo "configure and flags: test-ilp32 glibc/debian/build-debian.sh (Debian's build.mk options; CC"
	echo "  $T-gcc -mbranch-protection=bti -U_FILE_OFFSET_BITS -U_TIME_BITS; CFLAGS and ASFLAGS -pipe -O2 -g"
	echo "  + prefix maps)"
	echo
	echo "deviations from Debian's build: as for the released $V_GLIBC (MANIFEST of stage-runtime-20261027):"
	echo "  the cross triplet aarch64-linux-gnu_ilp32 and its layout, -mbranch-protection=bti, no memory"
	echo "  tagging, no libmvec, separate ILP32 headers, only the ILP32 libraries"
	echo
	echo "release build: test-ilp32 glibc/debian/check-debian-clean.sh in a fresh clean chroot (pristine"
	echo "  Debian 13 arm64 buildd base, thrown away afterwards) on an arm64 Debian 13 board: glibc's"
	echo "  Build-Depends from Debian, the released ILP32 compiler $V_GCC_CC, binutils $V_BU and"
	echo "  linux-libc-dev-ilp32 $V_LINUX from the signed repository (keyring fingerprint"
	echo "  D5723B340CBE7C99209182439C6A5E841E289B20); built and tested as an unprivileged user"
	echo "  (installed packages list below)"
	echo "  target code checks against the released $V_GLIBC:"
	cat "$CODECHECK"
	echo
	echo "testsuite of the release build (make check, natively on the board, in the same chroot):"
	grep -E '^[A-Z]+:' "$GR/tests.sum" | cut -d: -f1 | sort | uniq -c | sed 's/^/  /'
	grep -E '^(FAIL|XPASS|ERROR|UNRESOLVED):' "$GR/tests.sum" | sed 's/^/  /'
	echo "  elf/tst-audit23: a Debian xfail on every architecture"
	echo "  string/tst-memmove-overflow: GCC and clang sign-extend a constant offset of 2 GiB or more in an"
	echo "    address (objects larger than PTRDIFF_MAX are not supported); passes with the size as a"
	echo "    run-time value, memmove itself is fine"
	echo "  elf/tst-protected1a, tst-protected1b XPASS: Debian xfails on every architecture"
	echo
	echo "doc/: Debian's copyright and changelog of glibc"
	for p in "$STAGE"/*-ilp32; do
		echo
		echo "## $(basename "$p")"
		(cd "$p" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | LC_ALL=C sort | while read -r f; do
			if [ -L ".$f" ]; then echo "  $f -> $(readlink ".$f")"
			else echo "  $f $(sha256sum ".$f" | cut -c1-16)"; fi
		done)
	done
	echo
	echo "## build environment: packages installed in the clean chroot (dpkg-query)"
	sed 's/^/  /' "$GR/dpkg-l.txt"
}

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
		echo "  gcc-14-aarch64-linux-gnu-ilp32, g++-14-aarch64-linux-gnu-ilp32  $V_GCC_CC"
		echo "runtime: $V_GCC"
		echo "  (the GCC runtime packages stay at $V_GCC; binutils-aarch64-linux-gnu-ilp32 $V_BU,"
		echo "  libc6-ilp32/libc6-dev-ilp32 $V_GLIBC and linux-libc-dev-ilp32 $V_LINUX are released and unchanged)"
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
	n=$(git -C "$GCC_SRC" rev-list --count debian..ilp32)
	echo "  gcc:   Debian's 83 for the cross build to arm64 on trixie (debian/rules patch) + test-ilp32"
	echo "         glibc/toolchain/patches/gcc-14.2.0-debian/ ($n: $(git -C "$GCC_SRC" log --reverse --format=%s debian..ilp32 |
		sed 's/^\([^:]*: [^:]*\):.*/\1/' | paste -sd ';' | sed 's/;/; /g'))"
	echo "         = debian-gcc gcc-14.2.0 branch ilp32 $(git -C "$GCC_SRC" rev-parse --short ilp32)"
	o=$(git -C "$GCC_SRC" log --format=%s debian..ilp32)
	if grep -q "revert Debian's libgomp-omp_h-multilib" <<< "$o"; then
		echo "         (Debian's libgomp-omp_h-multilib reverted: its omp_nest_lock_t was 12 bytes/align 4 for"
		echo "         ILP32, libgomp's is 24/8; omp.h has configure's sizes again, as upstream)"
	fi
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
	echo "  - gcc: Debian's libgomp-omp_h-multilib not applied (reverted): wrong omp_nest_lock_t size for ILP32"
	echo "  - gcc: --disable-multiarch (gcc's aarch64 multiarch name is the LP64 triplet), --with-abi=ilp32"
	echo "    --with-multilib-list=ilp32 --disable-multilib, --enable-languages=c,c++, --disable-libsanitizer"
	echo "    (no ILP32 support); otherwise Debian's layout (gcc-cross/$T/14, -14 program suffix)"
	echo "  - prefix maps for build, toolchain and sysroot paths (no build path in the files)"
	echo "  - .dsc files pinned by sha256 (no Debian keyring for dpkg-source)"
	if [ -n "${HOSTINFO:-}" ]; then
		echo
		echo "release build (gcc-14, g++-14 trees): test-ilp32 glibc/toolchain/build-debian-clean.sh, in a fresh clean"
		echo "  chroot (pristine Debian 13 arm64 buildd base, thrown away afterwards) on an arm64 Debian 13 board:"
		echo "  build = host = aarch64-linux-gnu with Debian's gcc 14.2.0-19, target aarch64-linux-gnu_ilp32;"
		echo "  Build-Depends of gcc-14 14.2.0-19 from Debian, plus the released ILP32 packages from the signed"
		echo "  repository (keyring fingerprint D5723B340CBE7C99209182439C6A5E841E289B20), versions pinned:"
		echo "  binutils-aarch64-linux-gnu-ilp32 $V_BU, libc6-ilp32 and libc6-dev-ilp32 $V_GLIBC,"
		echo "  linux-libc-dev-ilp32 $V_LINUX; --with-sysroot=/ against them (installed packages list below)"
		sed 's/^/  /' "$CLEAN/build-env.txt"
		echo "  host linked against Debian 13's arm64 gmp, mpfr, mpc, isl, zlib, zstd; host flags -g -O2,"
		echo "  -Wl,-z,relro (Debian's for cross compilers); host binaries stripped; gcc --with-bugurl: the project's"
		echo "  tracker; target libraries -g -O2 -mbranch-protection=bti (+ prefix maps)"
		echo "  prefix /usr, headers /$HDR, libraries /usr/libilp32, gcc in /usr/lib/gcc-cross/$T/14 and"
		echo "  /usr/libexec/gcc-cross/$T/14; only the -14 names (meta packages add the unversioned links);"
		echo "  the target libraries' dev files (lib*.a, libgomp.spec, libgcc_s.so script, lib*.so links to"
		echo "  /usr/libilp32) in /usr/lib/gcc-cross/$T/14 as Debian's cross gcc packages; without include/ssp"
		echo "  (libssp and libitm are built but not packaged)"
		sed 's/^/  /' "$HOSTINFO"
		echo "  $(cat "$CLEAN/omp-check.txt")"
		echo "  target code checks:"
		cat "$CODECHECK"
		echo "gcc (board) configure: $(strings -a "$STAGE/gcc-14-aarch64-linux-gnu-ilp32/usr/bin/$T-gcc-14" | grep -m1 -- '--with-pkgversion')"
	fi
	echo
	echo "tests (QEMU, kernel ilp32-6.12.y Image-ilp32-6.12.y-{noa32,pac}): glibc check-abi 15/15;"
	echo "  test-ilp32 run-glibc-test.sh 5/5, NOTIME32=1 4/4; libgcc pac-ret unwind (run-pac.sh) 9/9 on"
	echo "  -cpu max and cortex-a35; glibc PAC/BTI/dirty arguments (pac-run.sh) 7/7 on both"
	if [ "$PARTS" = compiler ]; then
		echo "testsuites of the release build, in the same clean chroot (kernel $(sed -n 's/^kernel: //p' "$CLEAN/build-env.txt")):"
		for f in "$CLEAN"/testsuite/*.sum; do
			[ -f "$f" ] || { echo "  (none)"; continue; }
			echo "  $(basename "$f"):"
			sed -n '/=== .* Summary ===/,$p' "$f" | grep '^#' | sed 's/^/    /'
			grep -E '^(FAIL|XPASS|UNRESOLVED|ERROR):' "$f" | sed 's/^/    /'
		done
		[ -f "$CLEAN/testsuite/NOTES" ] && sed 's/^/  /' "$CLEAN/testsuite/NOTES"
		echo "installed toolchain test (toolchain-test.sh, the trees installed into a clean chroot): see the hand-off message"
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
	if [ "$PARTS" = compiler ]; then
		echo
		echo "## build environment: packages installed in the clean chroot (dpkg-query)"
		sed 's/^/  /' "$CLEAN/dpkg-l.txt"
	fi
}
if [ "$PARTS" = glibc ]; then manifest_glibc > "$STAGE/MANIFEST"; else manifest > "$STAGE/MANIFEST"; fi
for p in "$STAGE"/*-ilp32; do echo "$(basename "$p"): $(find "$p" \( -type f -o -type l \) | wc -l) files"; done
