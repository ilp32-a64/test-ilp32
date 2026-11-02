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
}
