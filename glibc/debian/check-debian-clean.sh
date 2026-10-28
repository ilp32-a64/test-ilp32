#!/bin/bash
# glibc's testsuite for the released AArch64 ILP32 glibc (2.41-12+deb13u4+ilp32a64.1), run natively on an
# arm64 Debian 13 system with an ILP32 kernel, in a fresh clean chroot (../toolchain/clean-chroot.sh):
# glibc's Build-Depends from Debian, the released ILP32 compiler, binutils and headers from the signed
# repository, then build-debian.sh (Debian's source, patches and options, as for the release) and
# "make check" as an unprivileged user. Also compares the rebuilt libraries with the released packages'
# (code and data; debug info, build ids and .comment left out). The chroot is thrown away afterwards.
#   check-debian-clean.sh                     on the board (as root), in $W
#   check-debian-clean.sh inner               inside the chroot (called by the first form)
#   $W/in/ilp32-a64-archive-keyring_*.deb      the repository's keyring (fingerprint checked)
#   $W/in/glibc-debian/                        this directory of test-ilp32 (build-debian.sh, patches/)
# Output: $W/glibc-check-out/: build and check logs, tests.sum, failures, compare.txt, dpkg-l.txt
set -euo pipefail
W=/srv/build/compilibary
T=aarch64-linux-gnu_ilp32
NAME=glibc-check
FPR=D5723B340CBE7C99209182439C6A5E841E289B20
GLIBC_VERSION=2.41-12+deb13u4
ILP32_DEPS="binutils-aarch64-linux-gnu-ilp32=2.44-3+ilp32a64.1
	gcc-14-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.2 g++-14-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.2
	gcc-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.2 g++-aarch64-linux-gnu-ilp32=14.2.0-19+ilp32a64.2
	libc6-ilp32=$GLIBC_VERSION+ilp32a64.1 libc6-dev-ilp32=$GLIBC_VERSION+ilp32a64.1
	linux-libc-dev-ilp32=6.12.114-1+ilp32a64.2 libgcc-s1-ilp32=14.2.0-19+ilp32a64.1
	libstdc++6-ilp32=14.2.0-19+ilp32a64.1 libatomic1-ilp32=14.2.0-19+ilp32a64.1
	libgomp1-ilp32=14.2.0-19+ilp32a64.1"
HDRDIR=/usr/$T/include
J=${J:-4}

if [ "${1:-}" != inner ]; then
	C=$W/fresh/$NAME
	O=$W/glibc-check-out
	KEYRING_DEB=$W/in/ilp32-a64-archive-keyring_2026.10.24_all.deb
	[ -f "$KEYRING_DEB" ] && [ -x "$W/in/glibc-debian/build-debian.sh" ] || { echo "missing inputs in $W/in"; exit 1; }
	[ ! -e "$O" ] || { echo "$O exists"; exit 1; }
	mkdir -p "$O"
	"$W/clean-chroot.sh" fresh $NAME
	trap '"$W/clean-chroot.sh" destroy $NAME' EXIT
	cp "$KEYRING_DEB" "$C/tmp/keyring.deb"
	mkdir -p "$C/build"
	cp -a "$W/in/glibc-debian" "$C/build/glibc-debian"
	install -m 755 "$0" "$C/build/check-debian-clean.sh"
	set +e
	"$W/clean-chroot.sh" run $NAME /bin/bash -c "J=$J /build/check-debian-clean.sh inner" > "$O/run.log" 2>&1
	rc=$?
	set -e
	tail -5 "$O/run.log"
	cp -a "$C/build/out/." "$O/" 2>/dev/null || true
	[ "$rc" -eq 0 ] || { echo "inner run failed ($rc), the chroot is kept: $C"; trap - EXIT; exit 1; }
	echo "results in $O"
	exit 0
fi

# --- inside the chroot ---
export DEBIAN_FRONTEND=noninteractive
O=/build/out
mkdir -p "$O"
log() { echo "==> $* ($(date +%H:%M))"; }

log "packages"
apt-get update -q > /dev/null
apt-get install -y -q --no-install-recommends ca-certificates gnupg file > /dev/null
dpkg -i /tmp/keyring.deb > /dev/null
o=$(gpg --show-keys --with-colons /usr/share/keyrings/ilp32-a64-archive.gpg)
grep -q "^fpr:::::::::$FPR:" <<< "$o" || { echo "keyring fingerprint mismatch"; exit 1; }
apt-get update -q > /dev/null
apt-get build-dep -y -q glibc=$GLIBC_VERSION > /dev/null
# shellcheck disable=SC2086
apt-get install -y -q --no-install-recommends $ILP32_DEPS > /dev/null
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' > "$O/dpkg-l.txt"
grep ilp32 "$O/dpkg-l.txt"
"$T-gcc" --version | head -1

# an unprivileged user builds and tests, as on Debian's buildds
useradd -m -u 2000 builder
mkdir -p /build/w /build/kheaders /build/install
cp -a /build/glibc-debian /build/w/
chown -R builder: /build
as_builder() { runuser -u builder -- env HOME=/home/builder "$@"; }

# the kernel UAPI headers of the released linux-libc-dev-ilp32 (the same kernel commit as the release)
log "kernel headers"
while read -r f; do
	case $f in "$HDRDIR"/*) [ -f "$f" ] && install -D -m 644 "$f" "/build/kheaders/${f#"$HDRDIR"/}" ;; esac
done < <(dpkg -L linux-libc-dev-ilp32)
test -f /build/kheaders/asm/unistd_ilp32.h
find /build/kheaders -type f | wc -l

log "source"
(cd /build/w && as_builder apt-get source -q --download-only glibc=$GLIBC_VERSION) > /dev/null
log "build"
set +e
as_builder env TC=/usr SYSROOT=/build/install KHEADERS=/build/kheaders DEB_WORK=/build/w J="$J" \
	bash /build/w/glibc-debian/build-debian.sh source configure build install
rc=$?
set -e
cp -a /build/w/logs "$O/build-logs"
[ $rc -eq 0 ] || { echo "build failed"; exit 1; }
cp /build/w/src/debian/testsuite-xfail-debian.mk "$O/" || echo "no testsuite-xfail-debian.mk"

# the rebuilt files against the released packages' (rtlddir /lib and slibdir /libilp32 are under /usr in
# the packages); ELF files compared after the same strip, so debug info, build ids and .comment
# (compiler build) do not count
log "compare"
norm() { # <elf in> <out>
	"$T-objcopy" --strip-all --remove-section=.comment --remove-section=.note.gnu.build-id \
		--remove-section=.gnu_debuglink "$1" "$2" 2> /dev/null
}
same=0 diff=0 miss=0
: > "$O/compare.txt"
for p in libc6-ilp32 libc6-dev-ilp32; do
	while read -r f; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		case $f in
		/usr/share/*) continue ;;
		/usr/lib/ld-linux-*) b=/build/install/lib/${f#/usr/lib/} ;;
		/usr/libilp32/*) b=/build/install/usr/libilp32/${f#/usr/libilp32/}
			[ -f "$b" ] || b=/build/install/libilp32/${f#/usr/libilp32/} ;;
		"$HDRDIR"/*) b=/build/install/usr/include/${f#"$HDRDIR"/} ;;
		*) b=/build/install$f ;;
		esac
		if [ ! -f "$b" ]; then echo "MISSING $f" >> "$O/compare.txt"; miss=$((miss+1)); continue; fi
		if cmp -s "$f" "$b"; then same=$((same+1)); continue; fi
		case $(file -b "$f") in
		ELF*)
			if norm "$f" /tmp/a && norm "$b" /tmp/b && cmp -s /tmp/a /tmp/b; then same=$((same+1)); continue; fi ;;
		"current ar archive"*)
			rm -rf /tmp/xa /tmp/xb; mkdir /tmp/xa /tmp/xb
			(cd /tmp/xa && ar x "$f") && (cd /tmp/xb && ar x "$b")
			ok=1
			if [ "$(ls /tmp/xa)" != "$(ls /tmp/xb)" ]; then ok=0; fi
			for m in $( [ $ok = 1 ] && ls /tmp/xa); do
				norm "/tmp/xa/$m" /tmp/a && norm "/tmp/xb/$m" /tmp/b && cmp -s /tmp/a /tmp/b || { ok=0; break; }
			done
			if [ $ok = 1 ]; then same=$((same+1)); continue; fi ;;
		esac
		echo "DIFFERENT $f" >> "$O/compare.txt"; diff=$((diff+1))
	done < <(dpkg -L $p)
done
echo "compared with the released packages: same $same, different $diff, missing $miss" | tee -a "$O/compare.txt"

log "make check"
set +e
(cd /build/w/build/glibc && as_builder make -k -j"$J" check test-wrapper=env) > "$O/check.log" 2>&1
set -e
# make writes tests.sum only when every subdirectory got through; else collect the results itself
if [ -f /build/w/build/glibc/tests.sum ]; then
	cp /build/w/build/glibc/tests.sum "$O/"
else
	echo "no tests.sum from make (build errors in the tests, see check.log): made from *.test-result"
	grep -E '\*\*\* |error:' "$O/check.log" | grep -v 'not remade' > "$O/check-errors.txt" || true
	find /build/w/build/glibc -name '*.test-result' -exec cat {} + | grep -E '^[A-Z]+:' | sort > "$O/tests.sum"
fi
grep -E '^(FAIL|XPASS|ERROR|UNRESOLVED):' "$O/tests.sum" | sort > "$O/failures.txt" || true
awk -F: '{print $1}' "$O/tests.sum" | sort | uniq -c | tee "$O/summary.txt"
log "done"
