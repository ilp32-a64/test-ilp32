# bzip2 1.0.8-6: debian/rules (dh; override_dh_auto_build-arch, override_dh_auto_test-arch,
# override_dh_auto_install-arch, override_dh_install, override_dh_link) for arm64
MAINT="hardening=+all"
# rules: DEB_CFLAGS_MAINT_APPEND -Wall -Winline; DEB_CPPFLAGS_MAINT_APPEND -D_REENTRANT -D_FILE_OFFSET_BITS=64;
# the Makefile's AR/RANLIB (ar, ranlib) -> the ILP32 binutils' ones
bz_vars() {
	printf '%s\n' "CC=$CC" "CFLAGS=$CFLAGS -Wall -Winline" \
		"CPPFLAGS=$CPPFLAGS -D_REENTRANT -D_FILE_OFFSET_BITS=64" "LDFLAGS=$LDFLAGS" "AR=$AR" "RANLIB=$RANLIB"
}
recipe_build() {
	local v; mapfile -t v < <(bz_vars)
	make -j"$J" libbz2.a bzip2 bzip2recover "${v[@]}"
}
# rules: dh_auto_test -- CC CFLAGS CPPFLAGS LDFLAGS (make test: runs ./bzip2 with the new libbz2.so)
recipe_check() {
	local v; mapfile -t v < <(bz_vars)
	make test "${v[@]}"
}
# rules: dh_auto_install -- PREFIX=$(CURDIR)/debian/tmp/usr, then dh_install moves usr/lib/libbz2.so.* and
# usr/lib/libbz2.a to usr/lib/<multiarch>, dh_link adds libbz2.so.1 -> libbz2.so.1.0.4 (runtime) and
# libbz2.so -> libbz2.so.1.0 (dev); libbz2-dev.install: usr/include, debian/bzip2.pc -> usr/share/pkgconfig
recipe_install() {
	local v; mapfile -t v < <(bz_vars)
	make install PREFIX="$RAW/usr" "${v[@]}"
	mkdir -p "$RAW$LIBDIR/pkgconfig" "$RAW$INCDIR"
	mv "$RAW"/usr/lib/libbz2.* "$RAW$LIBDIR/"
	rmdir "$RAW/usr/lib"
	mv "$RAW/usr/include/bzlib.h" "$RAW$INCDIR/"
	rmdir "$RAW/usr/include"
	ln -sfn libbz2.so.1.0.4 "$RAW$LIBDIR/libbz2.so.1"
	ln -sfn libbz2.so.1.0 "$RAW$LIBDIR/libbz2.so"
	# Debian's bzip2.pc (libdir ${exec_prefix}/lib, in /usr/share/pkgconfig) with the ILP32 paths, where
	# the ILP32 pkg-config looks
	sed -e 's|^libdir=.*|libdir=${exec_prefix}/libilp32|' \
		-e "s|^includedir=.*|includedir=\${prefix}/$T/include|" debian/bzip2.pc > "$RAW$LIBDIR/pkgconfig/bzip2.pc"
}
