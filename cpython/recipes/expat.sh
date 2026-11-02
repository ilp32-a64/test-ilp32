# expat 2.9.0-1~deb13u1: debian/rules (config-common-stamp, build/ and buildw/ config.status, build-stamp,
# install) for arm64; no test step in the rules
MAINT=
# rules: CFLAGS = dpkg CFLAGS + -Wall; LDFLAGS = -Wl,-Bsymbolic-functions + dpkg LDFLAGS
ex_configure() { # <build dir> <source copy> <extra CFLAGS>
	mkdir -p "$1"
	(cd "$1" && CFLAGS="$CFLAGS -Wall $3" CPPFLAGS="$CPPFLAGS" LDFLAGS="-Wl,-Bsymbolic-functions $LDFLAGS" \
		"../$2/configure" --host="$T" --prefix=/usr --mandir='${prefix}/share/man' --libdir='${prefix}/libilp32' \
		--includedir="$INCDIR")
}
recipe_build() {
	# config-common-stamp: src/ and srcw/ copies of expat/, srcw's library renamed libexpatw, buildconf.sh
	rm -rf src srcw
	mkdir -p src srcw
	tar cf - expat/* | tar --strip-components=1 -C src -xf -
	tar cf - expat/* | tar --strip-components=1 -C srcw -xf -
	sed -i -e "s,libexpat\.la,libexpatw.la," -e "s,libexpat_la,libexpatw_la," $(find srcw -name Makefile.am)
	(cd src && ./buildconf.sh)
	(cd srcw && ./buildconf.sh)
	ex_configure build src ""
	ex_configure buildw srcw "-DXML_UNICODE"
	make -j"$J" -C build/
	make -j"$J" -C buildw/lib all
}
# rules install: both installs into debian/tmp (buildw without the API headers), expat_config.h moved to
# usr/include/<multiarch> (here: the one ILP32 include directory)
recipe_install() {
	make -C build/ install DESTDIR="$RAW"
	make -C buildw/lib install DESTDIR="$RAW" APIHEADER=
	# the autotools-made cmake files (cmake/autotools/*__linux.cmake.in) assume libdir lib/<multiarch>: they
	# climb five directories up to the prefix, take headers from <prefix>/include and the library from
	# /lib/<basename of libdir>. For /usr/libilp32: four directories, the ILP32 include directory, and the
	# library relative to the prefix
	local c=$RAW$LIBDIR/cmake/expat-2.9.0
	local n
	n=$(grep -c '^get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)$' "$c/expat.cmake")
	[ "$n" = 4 ] || { echo "expat.cmake: $n parent steps, expected 4"; return 1; }
	sed -i -e '0,/^get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)$/{//d}' \
		-e 's|INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include"|INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/'"$T"'/include"|' \
		"$c/expat.cmake"
	sed -i 's|"/lib/libilp32/|"${_IMPORT_PREFIX}/libilp32/|g' "$c/expat-noconfig.cmake"
	! grep -q -e '"/lib/' -e '_IMPORT_PREFIX}/include"' "$c"/expat*.cmake || { echo "expat cmake files not fixed"; return 1; }
}
