#!/bin/bash
# Triplet audit of the ILP32 CPython set (compilibary): configure each autoconf source twice with the ILP32
# compiler, --host=aarch64-linux-gnu_ilp32 (as built) and --host=aarch64-linux-gnu (the name configure scripts
# know), and compare the results (config.status defines and substitutions, libtool). A difference not caused by
# the host name itself is a place where a configure script treats linux-gnu_ilp32 differently from linux-gnu
# (as ncurses' CF_XOPEN_SOURCE did). zlib, bzip2, libzstd and openssl choose by other means and are not audited.
#   audit-host.sh           on the board (root), inputs $W/in/py (src/, recipes/*.patches, toolchain/, deps/python3.13)
#   audit-host.sh inner     in the chroot
set -euo pipefail
W=/srv/build/compilibary
T=aarch64-linux-gnu_ilp32
SOURCES="xz-utils libffi expat ncurses readline sqlite3 util-linux python3.13"
if [ "${1:-}" != inner ]; then
	C=$W/fresh/py-audit
	O=$W/py-out/audit
	[ ! -e "$O" ] || { echo "$O exists"; exit 1; }
	mkdir -p "$O"
	"$W/clean-chroot.sh" fresh py-audit
	trap '"$W/clean-chroot.sh" destroy py-audit' EXIT
	mkdir -p "$C/build/in"
	cp -a "$W/in/py/src" "$W/in/py/recipes" "$W/in/py/toolchain" "$C/build/in/"
	cp -a "$W/in/py/deps/python3.13" "$C/build/in/deps"
	install -m 755 "$0" "$C/build/audit-host.sh"
	set +e
	"$W/clean-chroot.sh" run py-audit /usr/bin/env --default-signal /bin/bash /build/audit-host.sh inner > "$O/audit.log" 2>&1
	rc=$?
	set -e
	cp -a "$C/build/out/." "$O/" 2>/dev/null || true
	tail -3 "$O/audit.log"
	exit $rc
fi

export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
apt-get update -qq
for s in $SOURCES; do
	v=$(sed -n 's/^Version: //p' /build/in/src/$s/*.dsc)
	apt-get build-dep -y -qq "$s=$v" > /dev/null
done
apt-get install -y -qq --no-install-recommends passwd /build/in/toolchain/*.deb /build/in/deps/*.deb > /dev/null
useradd -m -u 2000 builder
mkdir -p /build/w /build/out
chown -R builder: /build/w /build/out /build/in
cat > /build/w/run.sh <<'EOF'
set -uo pipefail
T=aarch64-linux-gnu_ilp32
I=/usr/$T/include
export CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib PKG_CONFIG_LIBDIR=/usr/libilp32/pkgconfig PKG_CONFIG_PATH=
export CFLAGS="-g -O2 -mbranch-protection=bti" CXXFLAGS="-g -O2 -mbranch-protection=bti"
common="--prefix=/usr --libdir=/usr/libilp32 --includedir=$I"
cd /build/w
prep() { # <source>: unpacked with Debian's and our patches, the recipes' regeneration step; prints the configure dir
	local s=$1
	dpkg-source -x /build/in/src/$s/*.dsc src-$s > /dev/null 2>&1
	cd src-$s
	if [ -d /build/in/recipes/$s.patches ]; then for p in /build/in/recipes/$s.patches/*.patch; do patch -s -p1 < $p; done; fi
	case $s in
	xz-utils|libffi) autoreconf -f -i > /dev/null 2>&1 ;;
	expat) (cd expat && ./buildconf.sh > /dev/null 2>&1) ;;
	ncurses) sh debian/autoconf.sh > /dev/null 2>&1 ;;
	readline) cp -p /usr/share/misc/config.* support/ ;;
	sqlite3) dh_autoreconf --as-needed > /dev/null 2>&1 ;;
	util-linux) AM_OPTS=--copy LT_OPTS=--copy ./autogen.sh > /dev/null 2>&1 ;;
	python3.13) autoconf > /dev/null 2>&1 ;;
	esac
	cd ..
	if [ $s = expat ]; then echo src-$s/expat; else echo src-$s; fi
}
args() { # <source>: the configure options that matter for it (as the recipes use them)
	case $1 in
	ncurses) echo "$common --with-shared --enable-widec --without-gpm --with-termlib=tinfo --with-ticlib=tic --enable-pc-files --with-pkg-config-libdir=/usr/libilp32/pkgconfig --without-ada --without-tests" ;;
	util-linux) echo "$common --disable-all-programs --enable-libuuid --without-python --without-systemd --without-udev --without-selinux" ;;
	sqlite3) echo "$common --disable-tcl --enable-threadsafe --enable-load-extension --enable-fts4 --enable-fts5" ;;
	python3.13) echo "$common --with-platlibdir=libilp32 --enable-shared --with-computed-gotos --with-system-expat --without-ensurepip" ;;
	*) echo "$common" ;;
	esac
}
for s in SOURCES_LIST; do
	d=$(prep $s)
	for h in ilp32 lp64; do
		case $h in ilp32) host=$T ;; lp64) host=aarch64-linux-gnu ;; esac
		mkdir -p b-$s-$h
		# python: built without --host (config.guess); audited with both explicit hosts as well
		(cd b-$s-$h && "../$d/configure" --host=$host $(args $s) > configure.log 2>&1) || echo "$s $h: configure failed ($(tail -1 b-$s-$h/configure.log))"
	done
	out=/build/out/$s.diff
	{
		echo "## $s"
		for h in ilp32 lp64; do echo "host $h: $(sed -n "s/^host='\(.*\)'$/\1/p;s/^host_alias='\(.*\)'$/alias \1/p" b-$s-$h/config.log 2>/dev/null | head -2 | tr '\n' ' ')"; done
		echo "-- defines (D[...] in config.status) that differ:"
		diff <(grep '^D\["' b-$s-ilp32/config.status 2>/dev/null | sort) <(grep '^D\["' b-$s-lp64/config.status 2>/dev/null | sort) | grep '^[<>]'
		echo "-- substitutions (S[...]) that differ, the host names aside:"
		diff <(grep '^S\["' b-$s-ilp32/config.status 2>/dev/null | sort) <(grep '^S\["' b-$s-lp64/config.status 2>/dev/null | sort) | grep '^[<>]' |
			grep -v -E '^[<>] S\["(host|host_alias|host_os|host_cpu|host_vendor|build|build_alias|build_os|build_cpu|build_vendor|target|target_alias|target_os|target_cpu|target_vendor|ac_ct_[A-Z]*|ac_configure_args|cf_cv_system_name|MULTIARCH|PLATFORM_TRIPLET|SOABI|EXT_SUFFIX|ABIFLAGS)"\]='
		for lt in libtool; do
			[ -f b-$s-ilp32/$lt ] || continue
			echo "-- $lt settings that differ, the host names aside:"
			diff <(grep -E '^[a-z_]+=' b-$s-ilp32/$lt | sort) <(grep -E '^[a-z_]+=' b-$s-lp64/$lt | sort) | grep '^[<>]' | grep -v -E '^[<>] (host|host_alias|host_os|build|build_alias|build_os)='
		done
	} > $out 2>&1
	echo "$s: $(grep -c '^[<>]' $out) differing lines"
done
EOF
sed -i "s/SOURCES_LIST/$SOURCES/" /build/w/run.sh
chown builder: /build/w/run.sh
runuser -u builder -- bash /build/w/run.sh
