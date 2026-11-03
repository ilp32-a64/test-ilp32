#!/bin/bash
# Test-only run of python3.13 tests the build cannot run as a user would (compilibary).
# The packaged ILP32 set (debian's debs) is installed in a fresh clean chroot; nothing is rebuilt.
#  test_ctypes         test_dlerror runs a hard-coded "gcc", the LP64 compiler in a build chroot: here "gcc" is
#                      a link to the ILP32 compiler, first in PATH, for the test only
#  test_venv           excluded by the rules (-x); checks among others the libilp32 -> lib venv link (patch 0007);
#                      its pip tests use WHEEL_PKG_DIR (/usr/share/python-wheels): Debian's python3-pip-whl
#                      and python3-setuptools-whl (Architecture: all) are installed
# test_peg_generator is not run here: its C parser tests start an isolated (-I) interpreter, which ignores
# PYTHONPATH and so imports the installed test package instead of these files. It passes in the build.
# The test files come from the patched source, made by py-test-tar.sh (the set does not ship the test suite),
# unpacked as t/ with only Lib/test of Lib/, so that test.test_tools finds the source tree (Tools/, Include/...).
#   py-test-env.sh            on the board (root), inputs in $W/in/py-test/ (*.deb, tests.tar, SHA256SUMS)
#   py-test-env.sh inner      in the chroot
set -euo pipefail
W=/srv/build/compilibary
T=aarch64-linux-gnu_ilp32
if [ "${1:-}" != inner ]; then
	C=$W/fresh/py-test
	O=$W/py-out/py-test
	[ ! -e "$O" ] || { echo "$O exists"; exit 1; }
	mkdir -p "$O"
	"$W/clean-chroot.sh" fresh py-test
	trap '"$W/clean-chroot.sh" destroy py-test' EXIT
	mkdir -p "$C/build"
	cp -a "$W/in/py-test" "$C/build/in"
	install -m 755 "$0" "$C/build/py-test-env.sh"
	set +e
	"$W/clean-chroot.sh" run py-test /usr/bin/env --default-signal /bin/bash /build/py-test-env.sh inner > "$O/test.log" 2>&1
	rc=$?
	set -e
	cp -a "$C/build/out/." "$O/" 2>/dev/null || true
	grep -E "^== " "$O/test.log" | tail -8
	exit $rc
fi
ign=$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status)
[ "$((16#$ign))" = 0 ] || { echo "signals ignored ($ign)"; exit 1; }
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
cd /build/in && sha256sum --quiet -c SHA256SUMS
apt-get update -qq
apt-get install -y -qq --no-install-recommends passwd python3-pip-whl python3-setuptools-whl /build/in/*.deb > /build/apt.log 2>&1 ||
	{ tail -20 /build/apt.log; exit 1; }
mkdir -p /build/out
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' | sort > /build/out/dpkg-l.txt
echo "== installed: $(ls /build/in/*.deb | wc -l) local debs; wheels: $(ls /usr/share/python-wheels | tr '\n' ' ')"
echo "== $(python3.13-ilp32 -c 'import sys, sysconfig; print(sys.version.split()[0], sys.maxsize < 2**32, sysconfig.get_platform(), sysconfig.get_config_var("WHEEL_PKG_DIR"), sysconfig.get_config_var("CC"))')"
useradd -m -u 2000 builder
mkdir -p /build/w && chown builder: /build/w /build/out
cat > /build/w/run.sh <<'EOF'
set -uo pipefail
T=aarch64-linux-gnu_ilp32
cd /build/w
mkdir -p bin t && ln -sf /usr/bin/$T-gcc bin/gcc
tar -C t -xf /build/in/tests.tar
echo "== gcc in PATH: $(PATH=/build/w/bin:/usr/bin:/bin gcc -dumpmachine)"
for tst in test_ctypes test_venv; do
	PATH=/build/w/bin:/usr/bin:/bin PYTHONPATH=/build/w/t/Lib timeout 3600 \
		python3.13-ilp32 -m test -u cpu -v $tst > /build/out/$tst.log 2>&1
	echo "== $tst: exit $? ($(grep -E '^Total tests:' /build/out/$tst.log | tail -1); $(grep -E '^Result:' /build/out/$tst.log | tail -1))"
done
EOF
chown builder: /build/w/run.sh
runuser -u builder -- bash /build/w/run.sh
