#!/bin/bash
# Rebuild the whole ILP32 CPython set on the board, one source at a time, in the build order (compilibary).
# Each build is build-lib-clean.sh <source> (a fresh clean chroot); an earlier py-out/<source> is renamed to
# py-out/<source>.<tag>. Stops at the first failure. A thermal log runs alongside.
#   rebuild-set.sh <tag for the old outputs>      (as root on the board, in $W)
set -uo pipefail
W=/srv/build/compilibary
TAG=${1:?tag for the earlier outputs, e.g. trial-1102}
ORDER="zlib bzip2 xz-utils libzstd libffi expat ncurses util-linux readline sqlite3 openssl python3.13"
cd "$W"
L=$W/logs/rebuild-set-$(date -u +%Y%m%d-%H%M).log
for s in $ORDER; do
	if [ -e "py-out/$s" ]; then
		[ ! -e "py-out/$s.$TAG" ] || { echo "py-out/$s.$TAG exists" | tee -a "$L"; exit 1; }
		mv "py-out/$s" "py-out/$s.$TAG"
	fi
	echo "$(date -u +%FT%TZ) start $s" >> "$L"
	./thermal-log.sh "$s" &
	if ./build-lib-clean.sh "$s" > "logs/py-$s.out" 2>&1; then
		echo "$(date -u +%FT%TZ) ok $s" >> "$L"
	else
		echo "$(date -u +%FT%TZ) FAILED $s (logs/py-$s.out, py-out/$s/build.log)" >> "$L"
		wait
		exit 1
	fi
	wait
	# the chroot's mounts must be gone before the next build
	n=$(findmnt -rn -o TARGET | grep -c "$W/fresh/py-" || true)
	[ "$n" = 0 ] || { echo "$(date -u +%FT%TZ) STOP: $n mounts left after $s" >> "$L"; exit 1; }
done
echo "$(date -u +%FT%TZ) all done" >> "$L"
