#!/bin/bash
# The AArch64 ILP32 compiler for Debian 13 arm64, built natively on an arm64 Debian 13 board from the
# same sources and options as build-debian.sh: binutils 2.44-3 and gcc-14 14.2.0-19 (C, C++),
# build = host = aarch64-linux-gnu, target aarch64-linux-gnu_ilp32, linked against Debian 13's arm64
# gmp, mpfr, mpc, isl, zlib, zstd, jansson. gcc is built completely (also libgcc, libstdc++,
# libatomic, libgomp), so that its testsuites run on the board and its target libraries can be
# compared with those of the x86-hosted toolchain; the packages take the target files from there.
#   build-debian-native.sh [step...]     steps: binutils gcc (default both)
#
#   W        work directory (default /srv/build/compilibary): src/gcc-14.2.0 (git archive of debian-gcc
#            branch ilp32), src/gcc-14.changelog (Debian's), src/binutils-2.44 (apt-get source
#            binutils=2.44-3), sysroot/ (the glibc sysroot of the x86-hosted toolchain), build/,
#            raw-binutils/, raw-gcc/, logs/
#   J        parallel jobs (default 4)
# Prefix /usr, sysroot /, headers in /usr/aarch64-linux-gnu_ilp32/include, libraries in /usr/libilp32.
# gcc: the debian-gcc branch ilp32, as build-debian.sh (Debian's libgomp-omp_h-multilib reverted).
# Deviations besides those of build-debian.sh (also in the MANIFEST):
#   binutils --disable-shared    the host libbfd/libopcodes/libctf/libsframe are linked statically,
#                                so that they do not collide with Debian's libbinutils of the same names
#   binutils --disable-gprofng   gprofng (a profiler for the host) is not packaged
#   (binutils --libdir=/usr/lib/<triplet> as Debian's cross binutils: ld's scripts in
#    /usr/lib/aarch64-linux-gnu_ilp32/ldscripts; bfd-plugins/libdep is not packaged: static only)
#   gcc --with-bugurl            the ILP32 project's issue tracker
# Each step leaves a stamp ($B/.<step>) and is skipped when re-run; delete it to redo a step.
set -euo pipefail
W=${W:-/srv/build/compilibary}
T=aarch64-linux-gnu_ilp32
H=aarch64-linux-gnu
BU_SRC=$W/src/binutils-2.44
GCC_SRC=$W/src/gcc-14.2.0
TS=$W/sysroot
B=$W/build
LOGS=$W/logs
J=${J:-4}
HDRDIR=/usr/$T/include			# target system headers on the installed system
GCC_PKGVERSION="Debian 14.2.0-19+ilp32a64.2"
BU_PKGVERSION="GNU Binutils for Debian"
BUGURL=https://github.com/ilp32-a64/debian-ilp32/issues
export LC_ALL=C TZ=UTC
mkdir -p "$B" "$LOGS"

[ "$(dpkg --print-architecture)" = arm64 ] || { echo "not on an arm64 Debian system"; exit 1; }

# The board may have an ILP32 compiler installed: its tooldir /usr/<triplet> (as, ld, the libc headers)
# is gcc's tooldir here too (prefix /usr), and the build would use it. Run in a private mount namespace
# with /usr/<triplet> replaced by bin and lib of the binutils built here and an empty include
# directory (the libc headers come from the sysroot). Nothing of the installed system is changed.
if [ "${ILP32_NATIVE_NS:-}" != 1 ]; then
	TD=$W/tooldir
	rm -rf "$TD"; mkdir -p "$TD/include"
	ln -s "$W/raw-binutils/usr/$T/bin" "$TD/bin"
	ln -s "$W/raw-binutils/usr/$T/lib" "$TD/lib"
	mkdir -p "/usr/$T"
	exec unshare --mount --propagation private env ILP32_NATIVE_NS=1 /bin/bash -c \
		'mount --bind "$0" "$1" && shift && exec "$@"' "$TD" "/usr/$T" "$0" "$@"
fi

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

# Host programs: Debian's flags for cross compilers (gcc rules2, binutils rules: -g -O2,
# -Wl,-z,relro), build paths mapped; target libraries as in build-debian.sh.
hostenv() { # <source dir> <name> <changelog>
	local m f=""
	for m in "$1=/usr/src/$2" "$B=/usr/src/$2/build"; do
		f="$f -ffile-prefix-map=$m -fdebug-prefix-map=$m"
	done
	export CC=gcc-14 CXX=g++-14
	export CFLAGS="-g -O2$f" CXXFLAGS="-g -O2$f" LDFLAGS="-Wl,-z,relro"
	export SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -l "$3" -STimestamp)
}

strip_host() { # <dir>: strip the arm64 host binaries (Debian ships them stripped)
	find "$1" -type f \( -perm -u+x -o -name '*.so' \) -print0 | while IFS= read -r -d '' f; do
		o=$(file -b "$f")	# (not "file | grep -q": pipefail)
		if grep -q 'ELF 64-bit.*aarch64' <<< "$o"; then strip --strip-unneeded "$f"; fi
	done
	true
}

do_binutils() {
	rm -rf "$B/binutils" "$W/raw-binutils"; mkdir -p "$B/binutils"; cd "$B/binutils"
	hostenv "$BU_SRC" binutils-2.44 "$BU_SRC/debian/changelog"
	"$BU_SRC/configure" --build=$H --host=$H --target=$T \
		--disable-silent-rules --enable-obsolete --enable-plugins --enable-threads --enable-jansson \
		--enable-default-hash-style=gnu --enable-deterministic-archives \
		--disable-compressed-debug-sections --enable-new-dtags --disable-x86-used-note \
		--disable-default-execstack --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib/$T \
		--disable-shared --with-system-zlib \
		--with-pkgversion="$BU_PKGVERSION" --disable-werror --enable-initfini-array \
		--enable-ld=default --disable-gold --disable-gprofng --with-sysroot=/
	make -j"$J"
	make install DESTDIR="$W/raw-binutils"
	strip_host "$W/raw-binutils"
	o=$("$W/raw-binutils/usr/bin/$T-ld" --version); echo "${o%%$'\n'*}"
}

# omp.h's lock and depend types must have the sizes and alignments libgomp's configure measured
# (Debian's libgomp-omp_h-multilib computed omp_nest_lock_t from the pointer size, wrong for ILP32)
check_omp_h() { # <gcc driver> <libgomp Makefile> [gcc options]
	local cc=$1 mk=$2 v t=$(mktemp -d); shift 2
	declare -A n
	for v in OMP_LOCK_SIZE OMP_LOCK_ALIGN OMP_NEST_LOCK_SIZE OMP_NEST_LOCK_ALIGN OMP_DEPEND_KIND; do
		n[$v]=$(sed -n "s/^$v = \([0-9]*\)$/\1/p" "$mk")
		[ -n "${n[$v]}" ] || { echo "no $v in $mk"; return 1; }
	done
	printf '%s\n' '#include <omp.h>' \
		"_Static_assert (sizeof (omp_lock_t) == ${n[OMP_LOCK_SIZE]}, \"omp_lock_t size\");" \
		"_Static_assert (_Alignof (omp_lock_t) == ${n[OMP_LOCK_ALIGN]}, \"omp_lock_t align\");" \
		"_Static_assert (sizeof (omp_nest_lock_t) == ${n[OMP_NEST_LOCK_SIZE]}, \"omp_nest_lock_t size\");" \
		"_Static_assert (_Alignof (omp_nest_lock_t) == ${n[OMP_NEST_LOCK_ALIGN]}, \"omp_nest_lock_t align\");" \
		"_Static_assert (sizeof (omp_depend_t) == ${n[OMP_DEPEND_KIND]}, \"omp_depend_t size\");" > "$t/c.c"
	"$cc" "$@" -fopenmp -fsyntax-only "$t/c.c" || { rm -rf "$t"; echo "omp.h does not match libgomp"; return 1; }
	echo "omp.h matches libgomp: lock ${n[OMP_LOCK_SIZE]}/${n[OMP_LOCK_ALIGN]}, nest lock ${n[OMP_NEST_LOCK_SIZE]}/${n[OMP_NEST_LOCK_ALIGN]}, depend ${n[OMP_DEPEND_KIND]}"
	rm -rf "$t"
}

do_gcc() {
	rm -rf "$B/gcc" "$W/raw-gcc"; mkdir -p "$B/gcc"; cd "$B/gcc"
	hostenv "$GCC_SRC" gcc-14 "$W/src/gcc-14.changelog"
	# the target assembler and linker: the binutils just built (also used for the target libraries)
	export PATH=$W/raw-binutils/usr/bin:$PATH
	command -v $T-as
	# target headers and libraries at build time: the x86-hosted toolchain's glibc sysroot, arranged
	# as on the installed system, so that configure sees the same glibc and fixincludes can run.
	# Real directories (hard links), not symbolic links: ld adds the sysroot to the paths in a linker
	# script (libc.so) only when the script's real path is inside the sysroot; through a symbolic link
	# it would take /libilp32/libc.so.6 and /usr/libilp32/libc_nonshared.a of the running system.
	# (usr/lib must exist: gcc looks for the start files in <sysroot>/usr/lib/../libilp32)
	local BS=$B/build-sysroot
	rm -rf "$BS"; mkdir -p "$BS/usr/$T" "$BS/usr/lib" "$BS/lib"
	[ "$(readlink -f /usr/$T/bin/ld)" = "$(readlink -f "$W/raw-binutils/usr/$T/bin/ld")" ]
	[ -z "$(ls -A /usr/$T/include)" ]
	cp -al "$TS/usr/include" "$BS$HDRDIR"
	cp -al "$TS/libilp32" "$BS/libilp32"
	cp -al "$TS/usr/libilp32" "$BS/usr/libilp32"
	cp -al "$TS/lib/ld-linux-aarch64_ilp32.so.1" "$BS/lib/"
	if find "$BS" -type l -lname '/*' | grep .; then echo "absolute symbolic links in $BS"; return 1; fi
	# target libraries: Debian's -g -O2 + -mbranch-protection=bti, build paths mapped
	local TF="-g -O2 -mbranch-protection=bti" m
	for m in "$GCC_SRC=/usr/src/gcc-14" "$B=/usr/src/gcc-14/build" "$BS="; do
		TF="$TF -ffile-prefix-map=$m -fdebug-prefix-map=$m"
	done
	"$GCC_SRC/configure" --build=$H --host=$H --target=$T \
		--prefix=/usr --libexecdir=/usr/libexec --with-sysroot=/ --with-build-sysroot="$BS" \
		--with-native-system-header-dir=$HDRDIR \
		--with-pkgversion="$GCC_PKGVERSION" --with-bugurl=$BUGURL \
		--with-gcc-major-version-only --program-prefix=$T- --program-suffix=-14 --enable-linker-build-id \
		--enable-default-pie --with-system-zlib --without-target-system-zlib --enable-fix-cortex-a53-843419 \
		--disable-werror --enable-checking=release \
		--with-abi=ilp32 --with-multilib-list=ilp32 --disable-multilib --disable-multiarch \
		--enable-languages=c,c++ --enable-shared --without-included-gettext --enable-threads=posix \
		--enable-nls --enable-clocale=gnu --enable-libstdcxx-debug --enable-libstdcxx-time=yes \
		--with-default-libstdcxx-abi=new --enable-libstdcxx-backtrace --enable-gnu-unique-object \
		--disable-libquadmath --disable-libquadmath-support --enable-plugin --disable-libsanitizer \
		CFLAGS_FOR_TARGET="$TF" CXXFLAGS_FOR_TARGET="$TF"
	# keep the build machine's paths out of "gcc -v" (Configured with:, built into the drivers and
	# cc1*): the configure path as Debian's shows it (../src/configure); the build sysroot and the
	# target flags with their path maps are build-time settings (only that line: the subdirectory
	# configures still need them)
	sed -i -e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s|$GCC_SRC/configure|../src/configure|" \
		-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| '--with-build-sysroot=$BS'||" \
		-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| --with-build-sysroot=$BS||" \
		-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| 'CFLAGS_FOR_TARGET=[^']*'||" \
		-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| 'CXXFLAGS_FOR_TARGET=[^']*'||" Makefile
	grep -q -- "--with-build-sysroot=$BS" Makefile
	# (no "! cmd" checks: set -e does not stop at a negated command)
	if grep '^TOPLEVEL_CONFIGURE_ARGUMENTS' Makefile | grep -e /srv/ -e /home/ -e build-sysroot; then
		echo "build paths in TOPLEVEL_CONFIGURE_ARGUMENTS"; return 1
	fi
	make -j"$J"
	make install DESTDIR="$W/raw-gcc"
	check_omp_h "$W/raw-gcc/usr/bin/$T-gcc-14" "$B/gcc/$T/libgomp/Makefile" --sysroot="$BS"
	strip_host "$W/raw-gcc"
	"$W/raw-gcc/usr/bin/$T-gcc-14" -v 2>&1 | tail -1
	# the host programs that are packaged hold no build path
	local f
	for f in "$W"/raw-gcc/usr/bin/* "$W"/raw-gcc/usr/libexec/gcc-cross/$T/14/*; do
		[ -f "$f" ] || continue
		if grep -qaF -e /srv/ -e build-sysroot "$f"; then echo "build path in $f"; return 1; fi
	done
}

[ $# -gt 0 ] || set -- binutils gcc
for s in "$@"; do
	case $s in
	binutils|gcc) step $s do_$s ;;
	*) echo "unknown step $s"; exit 1 ;;
	esac
done
log "done: $*"
