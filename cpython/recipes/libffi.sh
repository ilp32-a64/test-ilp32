# libffi 3.4.8-2: debian/rules (stamp-configure, stamp-build, stamp-check, install) for arm64
MAINT=
recipe_build() {
	# rules: dh_autoreconf, then configure in build/ (CCASFLAGS adds -Wa,--gdwarf-5, LDFLAGS -Wl,-z,defs)
	update_autotools_config
	autoreconf -f -i
	mkdir -p build
	(cd build && ../configure --host="$T" --prefix=/usr --libdir="$LIBDIR" --includedir="$INCDIR" \
		--mandir='${prefix}/share/man' --infodir='${prefix}/share/info' \
		--enable-pax_emutramp --disable-exec-static-tramp --without-gcc-arch \
		CC="$CC" CXX="$CXX" CPPFLAGS="$CPPFLAGS" CFLAGS="$CFLAGS" CCASFLAGS="$CFLAGS -Wa,--gdwarf-5" \
		LDFLAGS="-Wl,-z,defs $LDFLAGS")
	make -j"$J" -C build
}
# rules: $(MAKE) -C build check 2>&1 | tee build/check.log (the pipe ignores failures)
CHECK_IGNORE_FAILURE=1
recipe_check() {
	make -C build check
}
# rules: make install DESTDIR, move usr/lib/* to usr/lib/<multiarch> (here: --libdir), libffi_pic.a from the
# convenience library, the headers to usr/include/<multiarch> (here: --includedir)
recipe_install() {
	make -C build DESTDIR="$RAW" install
	cp -p build/.libs/libffi_convenience.a "$RAW$LIBDIR/libffi_pic.a"
}
