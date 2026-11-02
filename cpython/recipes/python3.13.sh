# python3.13 3.13.5-2+deb13u5: debian/rules for arm64, natively (DEB_HOST_GNU_TYPE = DEB_BUILD_GNU_TYPE: PGO,
# LTO and the checks are on) with the ILP32 compiler: stamps/stamp-patch, the static flavour (build-static: the
# interpreter, make profile-opt with PGO+LTO, the built-in modules from Setup.local) and the shared flavour
# (build-shared: LTO, libpython3.13.so.1.0, the sysconfigdata and Makefile Debian installs), stamps/stamp-mincheck,
# stamps/stamp-check, the install target and binary-arch's .a edit. Not built: the nopie flavour (in trixie the
# same flags as the static one), the debug and shared-debug flavours, the documentation, tkinter, pybench
# (disabled in the rules as well). Line numbers below are debian/rules of 3.13.5-2+deb13u5.
# rules 66-73: dpkg_buildflags (and in trixie dpkg_pieflags) = DEB_BUILD_MAINT_OPTIONS="hardening=-pie optimize=-lto"
MAINT="hardening=-pie optimize=-lto"
VER=3.13
PVER=python$VER
PLAT=linux
# $(DEB_HOST_MULTIARCH) inside the python tree (sysconfigdata name, config dir, extension names): CPython's own
# triplet (Misc/platform_triplet.c; the ILP32 GCC prints nothing for --print-multiarch, so configure takes
# PLATFORM_TRIPLET); /usr/lib/$(DEB_HOST_MULTIARCH) -> $LIBDIR, /usr/include/$(DEB_HOST_MULTIARCH) -> $INCDIR
M=aarch64_ilp32-linux-gnu
SCRIPTDIR=usr/libilp32/$PVER                      # rules 271: scriptdir usr/lib/python$(VER), platlibdir libilp32
CONFDIR=$SCRIPTDIR/config-$VER-$M
PY_INTERPRETER=/usr/bin/$PVER-ilp32               # rules 124: /usr/bin/python$(VER) (Debian's own path)
# rules 29: on_buildd (the official arm64 build ran on a buildd): -network,-urlfetch and the buildd excludes
ON_BUILDD=yes
# rules 243-252
SUBST=(-e 's/-flto=auto//g' -e 's/-flto//g' -e 's/-fuse-linker-plugin//g' -e 's/-ffat-lto-objects//g'
	-e '/^OPT/s,-O3,-O2,' -e 's/-O3/-O2/g' -e 's/-fprofile-use *-fprofile-correction//g'
	-e "s/-specs=[^ '\"]*//g" -e "s/-fdebug-prefix-map=[^ '\"]*//g" -e "s/-ffile-prefix-map=[^ '\"]*//g"
	-e 's,^RUNSHARED *=.*,RUNSHARED=,' -e '/BLDLIBRARY/s/-L\. //')
# rules 103-110 (MIN_*) from debian/PVER-minimal.README.Debian.in
py_min() { awk -v k="$1" '/^  / && $2 == k { print $1 }' debian/PVER-minimal.README.Debian.in | tr '\n' ' '; }
# make's $(sort): byte order, duplicates removed
py_sort() { printf '%s\n' "$@" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }

# The rules' environment: rules 6-7 unexport LANG/LC_* and CFLAGS/CXXFLAGS/LDFLAGS/CPPFLAGS (the flags reach
# configure only as CFLAGS_NODIST/LDFLAGS_NODIST; an exported CFLAGS would also enter the Makefile's $(CFLAGS)).
# Every recipe function runs in a subshell, so this does not leak into build-lib-clean.sh's run.sh.
py_env() {
	local f
	# rules 175-186: the static flavour uses DPKG_PIE_*, in trixie the same values as DPKG_*
	DPKG_CPPFLAGS=$CPPFLAGS
	DPKG_CFLAGS=${CFLAGS//-fstack-protector-strong/-fstack-protector}
	DPKG_LDFLAGS=$LDFLAGS
	OPT_CFLAGS=
	for f in $DPKG_CFLAGS; do case $f in -O*) ;; *) OPT_CFLAGS+="$f " ;; esac; done
	# rules 211-241: with_lto (arm64), fat LTO objects for gcc >= 4.9, gcc-ar/gcc-ranlib
	LTO_CFLAGS="-g -fwrapv -O3 -flto -fuse-linker-plugin"
	if dpkg --compare-versions "$($CC --version | sed -n "/^$CC/s,.* ,,p")" ge 4.9; then
		LTO_CFLAGS+=" -ffat-lto-objects"
	fi
	OPT_CFLAGS+=$LTO_CFLAGS
	LTO_AR=$T-gcc-ar LTO_RANLIB=$T-gcc-ranlib
	unset LANG LC_ALL LC_CTYPE LC_COLLATE LC_TIME LC_NUMERIC LC_MESSAGES CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
	# rules 570-639: TEST_EXCLUDES for arm64, TESTOPTS
	TEST_RESOURCES=all
	TEST_EXCLUDES="test_ensurepip test_venv"
	if [ "$ON_BUILDD" = yes ]; then
		TEST_RESOURCES+=",-network,-urlfetch"
		TEST_EXCLUDES+=" test_tcl test_codecmaps_cn test_codecmaps_hk test_codecmaps_jp test_codecmaps_kr"
		TEST_EXCLUDES+=" test_codecmaps_tw test_normalization test_ossaudiodev"
	fi
	[ -e /dev/dsp ] || TEST_EXCLUDES+=" test_linuxaudiodev test_ossaudiodev"
	TEST_EXCLUDES+=" test_faulthandler"                    # arm64, LP: #1264354
	TEST_EXCLUDES+=" test_socket test_ttk_guionly"
	TEST_EXCLUDES+=" test_asyncio test_ftplib test_httplib test_imaplib test_nntplib test_poplib test_ssl"
	TEST_EXCLUDES+=" test_gdb"
	TESTOPTS="-j 1 -w -u$TEST_RESOURCES --timeout=3600 -x $(py_sort $TEST_EXCLUDES)"
	# rules 327-355: PROFILE_EXCLUDES, PROFILE_TASK (TEST_EXCLUDES is expanded at use, so it is included)
	local px="test_compiler test_subprocess test_multiprocessing test_socket test_socketserver
		test_thread test_threaded_import test_threadedtempfile test_threading test_threading_local
		test_threadsignals test_concurrent_futures test_ctypes test_dbm_dumb test_dbm_ndbm test_pydoc
		test_sundry test_signal test_ioctl test_gdb test_ensurepip test_venv
		test_asyncio test_ftplib test_httplib test_imaplib test_nntplib test_poplib test_ssl
		test_cmd_line_script test_zipimport_support
		test_multiprocessing_fork test_multiprocessing_forkserver test_multiprocessing_spawn
		test_cppext test_tools"
	# shellcheck disable=SC2086
	PROFILE_TASK="../Lib/test/regrtest.py -s -j 1 -unone,decimal -x $(py_sort $TEST_EXCLUDES $px)"
	# rules 363-376 common_configure_args, for the ILP32 layout: --libdir /usr/libilp32 (rules:
	# /usr/lib/$(DEB_HOST_MULTIARCH)), --with-platlibdir=libilp32 (stdlib, lib-dynload, config dir in
	# /usr/libilp32/python3.13), --includedir the ILP32 include directory; native: no --host/--build, no
	# config_site. Not available for ILP32: --with-dtrace dropped (systemtap), _dbm/_gdbm/_tkinter n/a,
	# the bluetooth headers absent (they are LP64-only in the chroot)
	CONFARGS=(--prefix=/usr --libdir="$LIBDIR" --with-platlibdir=libilp32 --includedir='${prefix}/aarch64-linux-gnu_ilp32/include'
		--enable-ipv6 --enable-loadable-sqlite-extensions --with-dbmliborder=bdb:gdbm --with-computed-gotos
		--without-ensurepip --with-system-expat --with-ssl-default-suites=openssl --with-system-libmpdec=no
		--with-wheel-pkg-dir=/usr/share/python-wheels/ "MKDIR_P=/bin/mkdir -p"
		py_cv_module__dbm=n/a py_cv_module__gdbm=n/a py_cv_module__tkinter=n/a
		ac_cv_header_bluetooth_bluetooth_h=no ac_cv_header_bluetooth_h=no)
}

# rules 531-551 __post_configure: the README's "extension" modules built in (Setup.local), makesetup, the
# _math.o rule; then (ILP32) CONFINCLUDEDIR = $(INCLUDEDIR): pyconfig.h is installed with the other headers in
# $INCDIR/python3.13 and CONFINCLUDEPY in the sysconfigdata/Makefile says so (Debian instead moves it to
# /usr/include/$(DEB_HOST_MULTIARCH)/python3.13 and installs debian/multiarch.h.in as pyconfig.h)
py_post_configure() { # <build dir>
	local d=$1 exts f
	exts=$(awk -v ORS='|' '$2 ~ /^extension$/ {print $1}' debian/PVER-minimal.README.Debian.in)
	grep -E "^#(${exts}XX)" Modules/Setup | sed -e 's/^#//' -e 's/-Wl,-Bdynamic//;s/-Wl,-Bstatic//' \
		>> "$d/Modules/Setup.local"
	(cd "$d" && ../Modules/makesetup -c ../Modules/config.c.in -s Modules \
		Modules/Setup.local Modules/Setup.bootstrap Modules/Setup.stdlib ../Modules/Setup)
	mv "$d/config.c" "$d/Modules/"
	make -C "$d" Makefile Modules/config.c
	sed '/^Modules\/_math.o: .*PY_STDMODULE_CFLAGS/d' "$d/Makefile" > "$d/Makefile.fixed"
	touch -r "$d/Makefile" "$d/Makefile.fixed"
	mv -f "$d/Makefile.fixed" "$d/Makefile"
	for f in Makefile.pre Makefile; do
		sed 's,^CONFINCLUDEDIR=.*,CONFINCLUDEDIR=\t$(INCLUDEDIR),' "$d/$f" > "$d/$f.ilp32"
		touch -r "$d/$f" "$d/$f.ilp32"
		mv -f "$d/$f.ilp32" "$d/$f"
	done
	grep -q '^CONFINCLUDEDIR=[[:space:]]*\$(INCLUDEDIR)$' "$d/Makefile"
}

# stamps/stamp-configure-static (rules 438-450) and stamps/stamp-configure-shared (rules 395-412)
py_configure() { # <build dir> <flavour arguments...>
	local d=$S/$1; shift
	rm -rf "$d"
	mkdir -p "$d"
	(cd "$d" && AR="$LTO_AR" RANLIB="$LTO_RANLIB" CFLAGS_NODIST="$DPKG_CPPFLAGS $OPT_CFLAGS" \
		LDFLAGS_NODIST="$DPKG_LDFLAGS $LTO_CFLAGS" ../configure "$@" "${CONFARGS[@]}")
	py_post_configure "$d"
}

recipe_build() (
	py_env
	# stamps/stamp-patch (rules 1545-1575): configure from Debian's patched configure.ac
	rm -rf autom4te.cache configure
	autoconf
	touch Parser/parser.c Parser/token.c
	touch Objects/obmalloc.c Python/dynamic_annotations.c Python/mysnprintf.c Python/pyctype.c
	ln -sf site-packages Lib/dist-packages
	touch Lib/test/certdata/nullcert.pem Lib/test/libregrtest/__init__.py Lib/test/tokenizedata/__init__.py
	grep -Eq '^#define PY_VERSION +"[^+]+"$' Include/patchlevel.h
	# stamps/stamp-build-static (rules 414-427): make profile-opt (with_pgo: native linux arm64), Debian's
	# PROFILE_TASK with profiled-build.diff's loop (regrtest -s until build/pynexttest is gone, errors ignored)
	py_configure build-static
	echo "PROFILE_TASK: $PROFILE_TASK"
	make -j"$J" -C build-static PROFILE_TASK="$PROFILE_TASK" profile-opt
	(cd build-static && ./python -c 'from _multiprocessing import SemLock')
	(cd build-static && ./python -c 'import _decimal')
	(cd build-static && ./python -c 'import math, cmath')
	# stamps/stamp-build-shared (rules 429-436), and the static library with PIC objects
	py_configure build-shared --enable-shared
	echo "XXXXXXX pyconfig.h"; cat build-shared/pyconfig.h || true
	make -j"$J" -C build-shared
	make -j"$J" -C build-shared LIBRARY=lib$PVER-pic.a lib$PVER-pic.a
)

# Debian's after-build checks: stamps/stamp-mincheck (rules 553-568, fails the build) and stamps/stamp-check
# (rules 645-701: make test of the static and the shared flavour, failures ignored as the rules' "-" does;
# the debug flavour's run is not done, it is not built)
recipe_check() (
	py_env
	local m b TEST_DIR SET_LOCPATH=
	for m in $(py_min module) $(py_min package) \
		$(awk '/^  / && $2 ~ /^extension/ { print $1 }' debian/PVER-minimal.README.Debian.in) $(py_min builtin); do
		echo "import $m"
	done > build-static/minmods.py
	(cd build-static && ./python -S ../debian/pymindeps.py minmods.py > mindeps.txt)
	if [ -x /usr/bin/dot ]; then
		(cd build-static && ./python -S ../debian/depgraph.py < mindeps.txt > mindeps.dot &&
			dot -Tpng -o mindeps.png mindeps.dot) || true
	fi
	(cd build-static && ./python -S ../debian/mincheck.py minmods.py mindeps.txt)
	echo "========== test environment ============"; env; echo "========================================"
	[ -f debian/testdir ] || mktemp -d > debian/testdir
	TEST_DIR=$(cat debian/testdir)
	[ ! -x /usr/bin/localedef ] || SET_LOCPATH="LOCPATH=$S/locales"
	for b in static shared; do
		printf '%s\n' '#! /bin/sh' 'set -x' "export $SET_LOCPATH" \
			"$S/build-static/python $S/debian/script.py test_results 'make test TESTOPTS=\"$TESTOPTS\"'" \
			'echo DONE' > "build-$b/run_tests"
		chmod 755 "build-$b/run_tests"
		echo "BEGIN test $b"
		# rules: .local/lib/$(PVER)/site-packages, the user site; the ILP32 one (patch 0005)
		mkdir -p "$TEST_DIR/$b/.local/libilp32/$PVER/site-packages"
		(cd "build-$b" && HOME=$TEST_DIR/$b time xvfb-run -a -e xvfb-run.log ./run_tests) ||
			echo "test $b: exit $? (ignored, as by the rules)"
		find "$TEST_DIR/$b"
		rm -rf "${TEST_DIR:?}/$b"
		echo "END test $b"
	done
	cp -p build-static/test_results debian/
)

# The install target (rules 866-1397) for the ILP32 layout and the four packages, and binary-arch's
# objcopy of the static libraries (rules 1493-1494) and its permission steps (rules 1508-1516)
recipe_install() (
	py_env
	local d=$RAW i b rv
	# stamps/stamp-control (rules 851-864): the one generated file the install uses
	sed -e "s/@PVER@/$PVER/g;s/@VER@/$VER/g;s/@SVER@/3.13.0~rc3/g" -e "s/@PRIORITY@/3130/g" \
		-e "s,@SCRIPTDIR@,/$SCRIPTDIR,g" -e "s,@INFO@,,g" -e "s,@HOST_QUAL@,:arm64,g" \
		< debian/EXTERNALLY-MANAGED.in > debian/EXTERNALLY-MANAGED
	# rules 875-892: install the static flavour (with_interp static); the sysconfigdata of the shared one
	install -d "$d/usr" "$d/$SCRIPTDIR/lib-dynload"
	make -C build-static install DESTDIR="$d"
	ls -l "$d/$SCRIPTDIR"/_sysconfigdata*
	sed "${SUBST[@]}" "build-shared/$(cat build-shared/pybuilddir.txt)/_sysconfigdata__${PLAT}_$M.py" \
		> "$d/$SCRIPTDIR/_sysconfigdata__${PLAT}_$M.py"
	# rules 886-888 (pyconfig.h to /usr/include/$(DEB_HOST_MULTIARCH)): not needed, see py_post_configure
	test -f "$d$INCDIR/$PVER/pyconfig.h"
	rm -f "$d/$SCRIPTDIR"/lib-dynload/*.py
	ls -l "$d/$SCRIPTDIR"/_sysconfigdata*
	sed -i "${SUBST[@]}" "$d/$SCRIPTDIR/_sysconfigdata__${PLAT}_$M.py"
	# rules 894-902
	find "$d/$SCRIPTDIR" -name '*_failed*.so'
	find "$d/$SCRIPTDIR" -name '*_failed*.so' | xargs -r rm -f
	for i in "$d/$SCRIPTDIR"/lib-dynload/*.so; do
		case "$i" in *$M*) continue ;; esac
		b=$(basename "$i" .cpython-313m.so)
		mv "$i" "$d/$SCRIPTDIR/lib-dynload/$b.cpython-313m-$M.so"
	done
	# rules 904-907: site-packages becomes the shared dist-packages, here the ILP32 counterpart of
	# /usr/lib/python3/dist-packages (patch 0003); its README is dropped
	mkdir -p "$d$LIBDIR/python3"
	mv "$d/$SCRIPTDIR/site-packages" "$d$LIBDIR/python3/dist-packages"
	rm -f "$d$LIBDIR"/python3/dist-packages/README*
	# rules 909-919
	rm -rf "$d/$SCRIPTDIR/ctypes/macholib"
	rm -f "$d/usr/share/man/man1/python3.1"
	if [ -d "$d/$SCRIPTDIR/ensurepip/_bundled" ]; then
		echo "don't ship the prebuilt ensurepip/_bundled wheels."
		rm -rf "$d/$SCRIPTDIR/ensurepip/_bundled"
	fi
	find "$d" -name 'wininst*.exe' | xargs -r rm -f
	# rules 921-923 (man pages): not installed, Debian's paths
	# rules 925-926: pdb3.13 -> the library's pdb.py, here as pdb3.13-ilp32 (its '#!' line is set below)
	ln -sf "../libilp32/$PVER/pdb.py" "$d/usr/bin/pdb$VER-ilp32"
	# rules 929-932: versioned install only
	rm -f "$d"/usr/bin/{idle3,pydoc3,python3,python3-config}
	rm -f "$d$LIBDIR/pkgconfig/python3.pc" "$d$LIBDIR/pkgconfig/python3-embed.pc"
	# the interpreter and pydoc under their ILP32 names (Debian's: /usr/bin/python3.13, pydoc3.13)
	mv "$d/usr/bin/$PVER" "$d$PY_INTERPRETER"
	mv "$d/usr/bin/pydoc$VER" "$d/usr/bin/pydoc$VER-ilp32"
	# rules 958: pygettext3.13, here as pygettext3.13-ilp32 (manual page not installed)
	cp -p Tools/i18n/pygettext.py "$d/usr/bin/pygettext$VER-ilp32"
	# rules 934-951: the shared library, its links (dh_link: relative) in libpython3.13
	cp -p "build-shared/lib$PVER.so.1.0" "$d$LIBDIR/"
	ln -s "lib$PVER.so.1.0" "$d$LIBDIR/lib$PVER.so.1"
	ln -s "../../lib$PVER.so.1" "$d/$CONFDIR/lib$PVER.so"
	ln -sf "lib$PVER.so.1" "$d$LIBDIR/lib$PVER.so"
	# rules 961-964: the Makefile of the shared build
	sed "${SUBST[@]}" build-shared/Makefile > "$d/$CONFDIR/Makefile"
	# rules 997-1004
	rv=0
	for i in $(awk '/^  / && $2 ~ /^extension/ { print $1 }' debian/PVER-minimal.README.Debian.in); do
		if [ -f "$d/$SCRIPTDIR/lib-dynload/$i.so" ]; then echo >&2 "extension $i not mentioned in Setup.dist"; rv=1; fi
	done
	[ "$rv" = 0 ]
	# rules 1006-1009 (/etc/python3.13/sitecustomize.py, Debian's path): not installed
	# rules 1015-1017: python3.13-config cleaned; under the ILP32 name instead of the triplet-prefixed copy
	sed -i "${SUBST[@]}" "$d/usr/bin/$PVER-config"
	mv "$d/usr/bin/$PVER-config" "$d/usr/bin/$PVER-ilp32-config"
	# rules 1035-1038: python-3.13.pc without libdir/-L${libdir}; the Cflags addition of the multiarch
	# pyconfig.h directory is not needed (pyconfig.h is in ${includedir}/python3.13)
	sed -i -e '/^libdir=/d;s/-L\${libdir} *//' "$d$LIBDIR/pkgconfig/python-$VER.pc"
	# rules 1040-1045: libpython3.13.a -> the config dir's (replaces the file the static install put there),
	# the PIC static library
	rm -f "$d$LIBDIR/lib$PVER.a"
	ln -s "$PVER/config-$VER-$M/lib$PVER.a" "$d$LIBDIR/lib$PVER.a"
	cp -p "build-shared/lib$PVER-pic.a" "$d/$CONFDIR/"
	# rules 1047-1049 (/usr/src/python3.13, Debian's path): not installed
	# rules 1100-1112: the test framework stays with the standard library (libpython3.13-stdlib); the
	# complete testsuite (libpython3.13-testsuite) is not one of the four packages
	find "$d/$SCRIPTDIR/test" -mindepth 1 -maxdepth 1 ! -name libregrtest ! -name support \
		! -name typinganndata ! -name regrtest.py ! -name test_support.py ! -name __init__.py \
		! -name __main__.py -exec rm -rf {} +
	# rules 1176-1178: PEP 668 marker
	install -m 644 debian/EXTERNALLY-MANAGED "$d/$SCRIPTDIR"
	# rules 1185-1203: '#!' lines to $(PY_INTERPRETER), executable
	while IFS= read -r -d '' i; do
		LC_ALL=C sed '1s,#!.*python[^ ]*\(.*\),#! '"$PY_INTERPRETER"'\1,' "$i" > "$i.temp"
		if cmp --quiet "$i" "$i.temp"; then
			rm -f "$i.temp"
		else
			[ -x "$i" ] || echo "fixed x file permissions: $i"
			mv -f "$i.temp" "$i"
			chmod 755 "$i"
			echo "fixed interpreter: $i"
		fi
	done < <(find "$d" -type f ! -name '*.so' -print0)
	# rules 1205-1225 (pixmap, binfmt, desktop entry: Debian's paths): not installed
	# rules 1227-1232
	find "$d" -name .cvsignore | xargs -r rm -f
	find "$d" -name '*.py[co]' | xargs -r rm -f
	find "$d" ! -name lib-dynload ! -name dist-packages -type d -empty -delete
	# rules 1384-1387: compatibility name of the sysconfigdata
	ln -s "_sysconfigdata__${PLAT}_$M.py" "$d/$SCRIPTDIR/_sysconfigdata__$M.py"
	# python3-defaults' python3-minimal has /usr/bin/python3 -> python3.13: python3-ilp32's command
	ln -s "$PVER-ilp32" "$d/usr/bin/python3-ilp32"
	# binary-arch, rules 1493-1494: no LTO sections in the static libraries
	find "$d/$CONFDIR" -name '*.a' ! -type l -print0 | xargs -0 -n 1 "$T-objcopy" -p --remove-section='.gnu.lto_.*'
	# binary-arch, rules 1508-1516
	chmod 644 "$d/$SCRIPTDIR/token.py"
	while IFS= read -r -d '' i; do
		if head -1 "$i" | grep -q '^#!'; then chmod 755 "$i"; echo "make executable: $i"; fi
	done < <(find "$d" -type f ! -perm 755 -print0)
	# (ILP32 check, not in the rules) the installed build configuration carries no LTO, profile, specs or
	# prefix-map flags, as Debian's cleaning intends
	if grep -nE -e '-flto|-ffat-lto|-fuse-linker-plugin|-fprofile-use|-specs=|-ffile-prefix-map|-fdebug-prefix-map' \
		"$d/$SCRIPTDIR/_sysconfigdata__${PLAT}_$M.py" "$d/$CONFDIR/Makefile" "$d/usr/bin/$PVER-ilp32-config"; then
		echo "build-only flags left in the installed configuration"; exit 1
	fi
)
