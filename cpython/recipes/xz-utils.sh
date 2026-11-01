# xz-utils 5.8.1-1+deb13u2: debian/rules (dh, compat 13: dh_autoreconf; override_dh_auto_configure-arch,
# -build-arch, -test-arch, -install-arch) for arm64: normal-build (shared liblzma, the programs) and
# static-build (liblzma.a, liblzma2 compat); xzdec-build only makes the xzdec/lzmadec programs (not built)
MAINT="hardening=+all"
# dh_auto_configure's arguments for the triplet, then the rules' ones; the flags as configure arguments
# (rules: dpkg-buildflags --export=configure); --host only, so configure runs its test programs natively
xz_configure() { # <build dir> <rules' arguments...>
	local d=$1; shift
	mkdir -p "$d"
	(cd "$d" && ../../configure --host="$T" --prefix=/usr --includedir="$INCDIR" --mandir=/usr/share/man \
		--infodir=/usr/share/info --sysconfdir=/etc --localstatedir=/var --disable-option-checking \
		--disable-silent-rules --libdir="$LIBDIR" --runstatedir=/run --disable-maintainer-mode \
		--disable-dependency-tracking gl_cv_posix_shell=/bin/sh "$@" \
		CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS")
}
recipe_build() {
	update_autotools_config
	autoreconf -f -i
	xz_configure debian/normal-build --enable-threads --disable-static --disable-xzdec --disable-lzmadec
	xz_configure debian/static-build --enable-threads --disable-shared --enable-liblzma2-compat \
		--disable-lzmainfo --disable-scripts --disable-xzdec --disable-lzmadec --disable-xz --disable-lzma-links
	make -j"$J" -C debian/normal-build
	make -j"$J" -C debian/static-build
}
# rules: dh_auto_test in each build directory (make check)
recipe_check() {
	make -j"$J" -C debian/normal-build check VERBOSE=1
	make -j"$J" -C debian/static-build check VERBOSE=1
}
# rules: dh_auto_install for static-build, then normal-build (make install DESTDIR=debian/tmp)
recipe_install() {
	make -C debian/static-build install DESTDIR="$RAW" AM_UPDATE_INFO_DIR=no
	make -C debian/normal-build install DESTDIR="$RAW" AM_UPDATE_INFO_DIR=no
}
