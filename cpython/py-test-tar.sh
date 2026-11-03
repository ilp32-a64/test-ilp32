#!/bin/bash
# tests.tar for py-test-env.sh (compilibary): the python3.13 source with Debian's and our patches, without
# Lib/ apart from Lib/test (the installed standard library is the one tested) and without debian/ and Doc/.
# Tools/peg_generator's C parser tests compile against the source's Include/, Parser/ and Python/. As in
# Debian's libpython3.13-testsuite, test_ctypes/test_macholib.py is left out (Debian drops ctypes.macholib).
#   py-test-tar.sh <python3.13 .dsc> <our patches dir> <out tar>
set -euo pipefail
DSC=$(realpath "$1"); PATCHES=$(realpath "$2"); OUT=$(realpath -m "$3")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
dpkg-source -x "$DSC" src > /dev/null 2>&1
cd src
for p in "$PATCHES"/*.patch; do patch -s -p1 < "$p"; done
rm -f Lib/test/test_ctypes/test_macholib.py
tar --owner=0 --group=0 --exclude=./debian --exclude=./Doc --exclude=./.pc \
	--exclude='./Lib/*' --exclude='./Lib/.*' -cf "$OUT" .
tar --owner=0 --group=0 -rf "$OUT" ./Lib/test
echo "$(tar -tf "$OUT" | wc -l) entries"
