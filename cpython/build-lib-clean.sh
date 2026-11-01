#!/bin/bash
# Release build of one source package of the AArch64 ILP32 CPython set: the Debian 13 source with Debian's
# patches (dpkg-source -x), built as its debian/rules builds it for arm64 but for the ILP32 triplet, natively
# in a fresh clean chroot on an arm64 Debian 13 board, as sbuild would: a fresh copy of the pristine base
# (clean-chroot.sh), the source's Build-Depends from Debian (apt-get build-dep), the ILP32 toolchain and
# the set's earlier libraries as packages. The copy is thrown away afterwards.
#   build-lib-clean.sh <source>            on the board (as root), in $W
#   build-lib-clean.sh inner <source>      inside the chroot (called by the first form)
# Inputs, all named exactly (no "newest file" guessing):
#   $W/in/py/src/<source>/          the .dsc and its files (fetch-sources.py: checked against Debian's InRelease)
#   $W/in/py/recipes/<source>.sh    what debian/rules does, for the ILP32 triplet (recipes/README)
#   $W/in/py/toolchain/             TOOLCHAIN=local (default): the ILP32 toolchain debs + SHA256SUMS
#                                   TOOLCHAIN=repo: the pinned versions below from the signed repository
#   $W/in/py/deps/<source>/         the set's earlier -ilp32 debs it needs + SHA256SUMS (none: no directory)
#   $W/in/ilp32-a64-archive-keyring_2026.10.24_all.deb
# Output: $W/py-out/<source>/ raw/ (the install tree), build.log, check.log, dpkg-l.txt, build-env.txt
set -euo pipefail
W=/srv/build/compilibary
T=aarch64-linux-gnu_ilp32
FPR=D5723B340CBE7C99209182439C6A5E841E289B20
# TOOLCHAIN=repo: the release toolchain (v2026.10.30), pinned
ILP32_TC="binutils-aarch64-linux-gnu-ilp32=2.44-3+ilp32a64.1 gcc-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.4
	g++-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.4 gcc-14-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.4
	g++-14-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.4 libc6-ilp32=2.41-12+deb13u4+ilp32a64.2
	libc6-dev-ilp32=2.41-12+deb13u4+ilp32a64.2 linux-libc-dev-ilp32=6.12.114-1+ilp32a64.2
	libgcc-s1-ilp32=14.2.0-19+ilp32a64.1 libatomic1-ilp32=14.2.0-19+ilp32a64.1
	libstdc++6-ilp32=14.2.0-19+ilp32a64.2 libgomp1-ilp32=14.2.0-19+ilp32a64.2"
J=${J:-4}

if [ "${1:-}" != inner ]; then
	SRC=${1:?source package}
	TOOLCHAIN=${TOOLCHAIN:-local}
	C=$W/fresh/py-$SRC
	O=$W/py-out/$SRC
	I=$W/in/py
	KEYRING_DEB=$W/in/ilp32-a64-archive-keyring_2026.10.24_all.deb
	[ -f "$I/recipes/$SRC.sh" ] && [ -f "$KEYRING_DEB" ] || { echo "missing $I/recipes/$SRC.sh or $KEYRING_DEB"; exit 1; }
	n=$(find "$I/src/$SRC" -maxdepth 1 -name "*.dsc" | wc -l)
	[ "$n" = 1 ] || { echo "$I/src/$SRC: $n .dsc files"; exit 1; }
	case $TOOLCHAIN in
	local) (cd "$I/toolchain" && sha256sum --quiet -c SHA256SUMS) || { echo "toolchain debs do not match SHA256SUMS"; exit 1; } ;;
	repo) ;;
	*) echo "TOOLCHAIN must be local or repo"; exit 1 ;;
	esac
	if [ -d "$I/deps/$SRC" ]; then
		(cd "$I/deps/$SRC" && sha256sum --quiet -c SHA256SUMS) || { echo "deps of $SRC do not match SHA256SUMS"; exit 1; }
	fi
	[ ! -e "$O" ] || { echo "$O exists"; exit 1; }
	mkdir -p "$O"
	"$W/clean-chroot.sh" fresh "py-$SRC"
	trap '"$W/clean-chroot.sh" destroy "py-$SRC"' EXIT
	mkdir -p "$C/build/in"
	cp "$KEYRING_DEB" "$C/build/in/keyring.deb"
	cp -a "$I/src/$SRC" "$C/build/in/src"
	cp "$I/recipes/$SRC.sh" "$C/build/in/recipe.sh"
	[ "$TOOLCHAIN" = repo ] || cp -a "$I/toolchain" "$C/build/in/toolchain"
	[ ! -d "$I/deps/$SRC" ] || cp -a "$I/deps/$SRC" "$C/build/in/deps"
	install -m 755 "$0" "$C/build/build-lib-clean.sh"
	{
		echo "source: $(cd "$I/src/$SRC" && ls *.dsc) $(sha256sum "$I/src/$SRC"/*.dsc | cut -c1-16)"
		echo "recipe: $(sha256sum "$I/recipes/$SRC.sh" | cut -c1-16)"
		echo "toolchain: $TOOLCHAIN"
	} > "$O/build-env.txt"
	set +e
	"$W/clean-chroot.sh" run "py-$SRC" /bin/bash -c "J=$J TOOLCHAIN=$TOOLCHAIN /build/build-lib-clean.sh inner $SRC" > "$O/build.log" 2>&1
	rc=$?
	set -e
	tail -3 "$O/build.log"
	[ "$rc" -eq 0 ] || { echo "inner build failed ($rc), the chroot is kept: $C"; trap - EXIT; exit 1; }
	cp -a "$C/build/raw" "$C/build/dpkg-l.txt" "$O/"
	cat "$C/build/build-env.txt" >> "$O/build-env.txt"
	[ ! -f "$C/build/log/check.log" ] || cp "$C/build/log/check.log" "$O/"
	exit 0
fi

# ---- inside the fresh chroot (as root; the build itself runs as the user builder) ----
SRC=$2
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 TZ=UTC
cd /build
apt-get update
apt-get install -y --no-install-recommends ca-certificates gnupg file
dpkg -i /build/in/keyring.deb
o=$(gpg --show-keys --with-colons /usr/share/keyrings/ilp32-a64-archive.gpg)
grep -q "^fpr:::::::::$FPR:" <<< "$o" || { echo "keyring fingerprint is not $FPR"; exit 1; }
apt-get update
dsc=$(ls /build/in/src/*.dsc)
ver=$(sed -n 's/^Version: //p' "$dsc")
apt-get build-dep -y "$SRC=$ver"
if [ "$TOOLCHAIN" = repo ]; then
	# shellcheck disable=SC2086
	apt-get install -y --no-install-recommends $ILP32_TC
else
	apt-get install -y --no-install-recommends /build/in/toolchain/*.deb
fi
[ ! -d /build/in/deps ] || apt-get install -y --no-install-recommends /build/in/deps/*.deb
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' | sort > /build/dpkg-l.txt
{
	echo "kernel: $(uname -r)"
	echo "ILP32 gcc: $($T-gcc --version | head -1)"
	echo "dpkg: $(dpkg-query -W -f '${Version}' dpkg)"
} > /build/build-env.txt

useradd -m -u 2000 builder
mkdir -p /build/src /build/raw /build/log
chown -R builder: /build/src /build/raw /build/log /build/in
runuser -u builder -- dpkg-source -x "$dsc" /build/src/pkg
cat > /build/run.sh <<'EOF'
#!/bin/bash
# The build as the user builder: the common environment (recipes/README), then the recipe.
set -euo pipefail
T=aarch64-linux-gnu_ilp32
S=/build/src/pkg
RAW=/build/raw
J=${J:-4}
cd "$S"
export LC_ALL=C.UTF-8 TZ=UTC HOME=/home/builder
export SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -STimestamp)
. /build/in/recipe.sh
# dpkg-buildflags of trixie for arm64 with the recipe's DEB_BUILD_MAINT_OPTIONS, run in the source
# directory (its -ffile-prefix-map); -mbranch-protection=standard -> bti (GCC has no pac-ret for ILP32)
export DEB_BUILD_MAINT_OPTIONS=${MAINT:-}
for v in CFLAGS CPPFLAGS CXXFLAGS LDFLAGS; do
	f=$(dpkg-buildflags --get $v)
	f=${f//-mbranch-protection=standard/-mbranch-protection=bti}
	export "$v=$f"
done
unset DEB_BUILD_MAINT_OPTIONS
export CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib NM=$T-nm STRIP=$T-strip OBJDUMP=$T-objdump
# only ILP32 .pc files (the arm64 Build-Depends bring LP64 ones)
export PKG_CONFIG_LIBDIR=/usr/libilp32/pkgconfig PKG_CONFIG_PATH=
LIBDIR=/usr/libilp32
INCDIR=/usr/$T/include
# dh_update_autotools_config: Debian's config.sub/config.guess (they know aarch64-linux-gnu_ilp32)
update_autotools_config() {
	local f
	while read -r f; do cp /usr/share/misc/"$(basename "$f")" "$f"; done < <(find . -name config.sub -o -name config.guess)
}
echo "== flags: CFLAGS=$CFLAGS"; echo "   CPPFLAGS=$CPPFLAGS"; echo "   LDFLAGS=$LDFLAGS"
echo "== recipe_build ($(date -u +%T))"; recipe_build
if declare -F recipe_check > /dev/null; then
	echo "== recipe_check ($(date -u +%T))"
	set +e; ( set -e; recipe_check ) > /build/log/check.log 2>&1; rc=$?; set -e
	echo "check exit $rc (see check.log)"; tail -5 /build/log/check.log
	[ "$rc" -eq 0 ] || [ "${CHECK_IGNORE_FAILURE:-}" = 1 ] || { echo "check failed"; exit 1; }
fi
echo "== recipe_install ($(date -u +%T))"; recipe_install
find "$RAW" -name '*.la' -delete
EOF
chmod 755 /build/run.sh
runuser -u builder -- /build/run.sh
# no build machine paths in the install tree
if grep -rlaF -e /home/ -e /srv/ /build/raw; then echo "build machine paths in the files above"; exit 1; fi
n=$({ grep -rlaF /build/src/ /build/raw || true; } | wc -l)
echo "files with /build/src/ (not covered by -ffile-prefix-map): $n" | tee -a /build/build-env.txt
