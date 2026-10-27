#!/bin/bash
# Release build of the AArch64 ILP32 compiler for Debian 13 arm64 (gcc-14 14.2.0-19, C and C++ with the
# target libraries) in a fresh, clean chroot on an arm64 Debian 13 system, as sbuild would build it:
# a fresh copy of the pristine base (clean-chroot.sh), gcc-14's Build-Depends from Debian, and as the
# ILP32 build dependencies the released ILP32 packages from the signed apt repository (as Debian's cross
# gcc build-depends on libc6-dev-arm64-cross). The copy is thrown away afterwards.
#   [CHECK=1] build-debian-clean.sh           on the board (as root), in $W
#   build-debian-clean.sh inner               inside the chroot (called by the first form)
#   CHECK=1   also run the libgomp and libstdc++ testsuites in the same chroot (results in $W/clean-out/)
#
#   $W/in/gcc-14.2.0-ilp32-<commit>.tar.xz     debian-gcc branch ilp32 (git archive), $W/src/gcc-14.changelog
#   $W/in/ilp32-a64-archive-keyring_*.deb      the repository's keyring (fingerprint checked)
# Output: $W/clean-out/raw-gcc (make install DESTDIR, host binaries stripped), build.log, dpkg-l.txt,
# omp-check.txt, build-env.txt
# Options as build-debian-native.sh (Debian's cross build, our layout), but with --with-sysroot=/ and the
# ILP32 libc and binutils installed as packages, so no build sysroot and no private mount namespace.
set -euo pipefail
W=/srv/build/compilibary
T=aarch64-linux-gnu_ilp32
H=aarch64-linux-gnu
NAME=gcc-clean
GCC_COMMIT=b4953f9e8		# debian-gcc branch ilp32: Debian's patches, the omp.h revert, 4 ILP32 patches
FPR=D5723B340CBE7C99209182439C6A5E841E289B20
# the released ILP32 packages the build depends on (debian's repository, versions pinned)
ILP32_DEPS="binutils-aarch64-linux-gnu-ilp32=2.44-3+ilp32a64.1 libc6-ilp32=2.41-12+deb13u4+ilp32a64.1
	libc6-dev-ilp32=2.41-12+deb13u4+ilp32a64.1 linux-libc-dev-ilp32=6.12.114-1+ilp32a64.2"
GCC_PKGVERSION="Debian 14.2.0-19+ilp32a64.2"
BUGURL=https://github.com/ilp32-a64/debian-ilp32/issues
HDRDIR=/usr/$T/include
J=${J:-4}

if [ "${1:-}" != inner ]; then
	C=$W/fresh/$NAME
	O=$W/clean-out
	# the inputs, named exactly (no "newest file" guessing)
	GCC_TAR=$W/in/gcc-14.2.0-ilp32-$GCC_COMMIT.tar.xz
	KEYRING_DEB=$W/in/ilp32-a64-archive-keyring_2026.10.24_all.deb
	[ -f "$GCC_TAR" ] && [ -f "$KEYRING_DEB" ] || { echo "missing $GCC_TAR or $KEYRING_DEB"; exit 1; }
	# the source has configure's nest lock size in omp.h.in (the revert) and the libatomic note fix
	o=$(tar -xJOf "$GCC_TAR" gcc-14.2.0/libgomp/omp.h.in)
	grep -q '_x\[@OMP_NEST_LOCK_SIZE@\]' <<< "$o" || { echo "$GCC_TAR: omp.h.in without the revert"; exit 1; }
	o=$(tar -xJOf "$GCC_TAR" gcc-14.2.0/libatomic/config/linux/aarch64/atomic_16.S)
	grep -q '\.word 12;' <<< "$o" || { echo "$GCC_TAR: atomic_16.S without the ELF32 note"; exit 1; }
	[ ! -e "$O" ] || { echo "$O exists"; exit 1; }
	mkdir -p "$O"
	"$W/clean-chroot.sh" fresh $NAME
	trap '"$W/clean-chroot.sh" destroy $NAME' EXIT
	cp "$KEYRING_DEB" "$C/tmp/keyring.deb"
	mkdir -p "$C/build/src"
	tar -C "$C/build/src" -xJf "$GCC_TAR"
	cp "$W/src/gcc-14.changelog" "$C/build/src/"
	install -m 755 "$0" "$C/build/build-debian-clean.sh"
	echo "gcc source: $(basename "$GCC_TAR") $(sha256sum < "$GCC_TAR" | cut -c1-16)" > "$O/build-env.txt"
	set +e
	"$W/clean-chroot.sh" run $NAME /bin/bash -c "J=$J /build/build-debian-clean.sh inner" > "$O/build.log" 2>&1
	rc=$?
	set -e
	tail -3 "$O/build.log"
	[ "$rc" -eq 0 ] || { echo "inner build failed ($rc), the chroot is kept: $C"; trap - EXIT; exit 1; }
	cp -a "$C/build/raw-gcc" "$C/build/dpkg-l.txt" "$C/build/omp-check.txt" "$O/"
	cat "$C/build/build-env.txt" >> "$O/build-env.txt"
	if [ "${CHECK:-}" = 1 ]; then
		# the testsuites against the installed (released) glibc, in the same clean chroot
		"$W/clean-chroot.sh" run $NAME /bin/bash -c \
			"cd /build/build && make -k -j$J check-target-libgomp check-target-libstdc++-v3" > "$O/check.log" 2>&1 || true
		mkdir -p "$O/testsuite"
		for f in "$C"/build/build/$T/libgomp/testsuite/libgomp.{sum,log} "$C"/build/build/$T/libstdc++-v3/testsuite/libstdc++.{sum,log}; do
			[ -f "$f" ] && cp "$f" "$O/testsuite/"
		done
		for f in "$O"/testsuite/*.sum; do echo "$(basename "$f"):"; sed -n '/=== .* Summary ===/,$p' "$f"; done
	fi
	ls -la "$O"
	exit 0
fi

# ---- inside the fresh chroot ----
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 TZ=UTC
cd /build
apt-get update
apt-get install -y --no-install-recommends ca-certificates gnupg file
# the ILP32 repository: its keyring, checked against the fingerprint debian gave
dpkg -i /tmp/keyring.deb
o=$(gpg --show-keys --with-colons /usr/share/keyrings/ilp32-a64-archive.gpg)
grep -q "^fpr:::::::::$FPR:" <<< "$o" || { echo "keyring fingerprint is not $FPR"; exit 1; }
cat /etc/apt/sources.list.d/ilp32-a64.sources
apt-get update
apt-get build-dep -y gcc-14=14.2.0-19
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $ILP32_DEPS
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' | sort > /build/dpkg-l.txt
{ echo "kernel: $(uname -r)"; echo "native gcc: $(gcc-14 --version | head -1)"; } > /build/build-env.txt

S=/build/src/gcc-14.2.0
B=/build/build
mkdir -p "$B"; cd "$B"
f=""
for m in "$S=/usr/src/gcc-14" "$B=/usr/src/gcc-14/build"; do f="$f -ffile-prefix-map=$m -fdebug-prefix-map=$m"; done
export CC=gcc-14 CXX=g++-14 CFLAGS="-g -O2$f" CXXFLAGS="-g -O2$f" LDFLAGS="-Wl,-z,relro"
export SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -l /build/src/gcc-14.changelog -STimestamp)
TF="-g -O2 -mbranch-protection=bti$f"
"$S/configure" --build=$H --host=$H --target=$T \
	--prefix=/usr --libexecdir=/usr/libexec --with-sysroot=/ --with-native-system-header-dir=$HDRDIR \
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
# Configured with: as Debian's (../src/configure), without the target flags' path maps
sed -i -e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s|$S/configure|../src/configure|" \
	-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| 'CFLAGS_FOR_TARGET=[^']*'||" \
	-e "/^TOPLEVEL_CONFIGURE_ARGUMENTS=/s| 'CXXFLAGS_FOR_TARGET=[^']*'||" Makefile
if grep '^TOPLEVEL_CONFIGURE_ARGUMENTS' Makefile | grep -e /build/ -e prefix-map; then echo "build paths in TOPLEVEL_CONFIGURE_ARGUMENTS"; exit 1; fi
make -j"$J"
make install DESTDIR=/build/raw-gcc

# omp.h's lock and depend types against libgomp's configured sizes and alignments
mk=$B/$T/libgomp/Makefile
declare -A n
for v in OMP_LOCK_SIZE OMP_LOCK_ALIGN OMP_NEST_LOCK_SIZE OMP_NEST_LOCK_ALIGN OMP_DEPEND_KIND; do
	n[$v]=$(sed -n "s/^$v = \([0-9]*\)$/\1/p" "$mk"); [ -n "${n[$v]}" ] || { echo "no $v"; exit 1; }
done
printf '%s\n' '#include <omp.h>' \
	"_Static_assert (sizeof (omp_lock_t) == ${n[OMP_LOCK_SIZE]}, \"omp_lock_t size\");" \
	"_Static_assert (_Alignof (omp_lock_t) == ${n[OMP_LOCK_ALIGN]}, \"omp_lock_t align\");" \
	"_Static_assert (sizeof (omp_nest_lock_t) == ${n[OMP_NEST_LOCK_SIZE]}, \"omp_nest_lock_t size\");" \
	"_Static_assert (_Alignof (omp_nest_lock_t) == ${n[OMP_NEST_LOCK_ALIGN]}, \"omp_nest_lock_t align\");" \
	"_Static_assert (sizeof (omp_depend_t) == ${n[OMP_DEPEND_KIND]}, \"omp_depend_t size\");" > /build/omp.c
/build/raw-gcc/usr/bin/$T-gcc-14 -fopenmp -fsyntax-only /build/omp.c
echo "omp.h matches libgomp's configure: omp_lock_t ${n[OMP_LOCK_SIZE]}/${n[OMP_LOCK_ALIGN]}, omp_nest_lock_t ${n[OMP_NEST_LOCK_SIZE]}/${n[OMP_NEST_LOCK_ALIGN]}, omp_depend_t ${n[OMP_DEPEND_KIND]}" | tee /build/omp-check.txt

# strip the arm64 host binaries; the packaged host programs hold no build path
find /build/raw-gcc -type f \( -perm -u+x -o -name '*.so' \) -print0 | while IFS= read -r -d '' x; do
	o=$(file -b "$x"); if grep -q 'ELF 64-bit.*aarch64' <<< "$o"; then strip --strip-unneeded "$x"; fi
done
for x in /build/raw-gcc/usr/bin/* /build/raw-gcc/usr/libexec/gcc-cross/$T/14/*; do
	[ -f "$x" ] || continue
	# (only the path: the drivers know the -f*-prefix-map options by name)
	if grep -qaF /build/ "$x"; then echo "build path in $x"; exit 1; fi
done
/build/raw-gcc/usr/bin/$T-gcc-14 -v 2>&1 | tail -1
