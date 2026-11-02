# ncurses 6.5+20250216-2: debian/rules (config.guess-stamp, the obj, obj-static, obj-wide and obj-wide-static
# configure/build, install-indep, install-arch) for arm64; no 32/64 biarch builds on arm64, the examples
# (obj-test, ncurses-examples) and the terminfo data (ncurses-base, ncurses-term) are not part of the set
MAINT="hardening=+bindnow"
export ARFLAGS=-crv
# rules' CONFARGS for the triplet: --libdir/--with-pkg-config-libdir /usr/libilp32, --includedir the ILP32
# include directory, --host only (configure runs its test programs natively), --without-gpm (no ILP32 gpm)
nc_configure() { # <obj dir> <flavour arguments...>
	local d=$1; shift
	mkdir -p "$d"
	(cd "$d" && ../configure --host="$T" --prefix=/usr --includedir="$INCDIR" --with-shared \
		--mandir=/usr/share/man --with-manpage-format=normal --without-profile --without-debug \
		--disable-rpath --disable-stripping --enable-const --enable-pc-files \
		--with-pkg-config-libdir="$LIBDIR/pkgconfig" --libdir="$LIBDIR" --with-install-prefix="$RAW" \
		--without-ada --without-tests --without-progs --without-gpm --enable-symlinks \
		--disable-setuid-environ --disable-root-access --disable-termcap \
		--with-default-terminfo-dir=/etc/terminfo \
		--with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
		--with-ticlib=tic --with-termlib=tinfo --with-versioned-syms --disable-wattr-macros \
		--disable-relink --disable-pkg-ldflags --enable-overwrite --with-xterm-kbs=del "$@")
}
recipe_build() {
	# config.guess-stamp: dh_update_autotools_config, dh_autoreconf debian/autoconf.sh
	update_autotools_config
	sh debian/autoconf.sh
	nc_configure obj --without-normal --disable-widec
	nc_configure obj-static --without-shared --disable-widec
	nc_configure obj-wide --without-normal --with-progs --enable-widec
	nc_configure obj-wide-static --without-shared --enable-widec
	local d
	for d in obj obj-static obj-wide obj-wide-static; do make -j"$J" -C "$d"; done
}
recipe_install() {
	# install-indep: the narrow libraries without libtinfo/libtic (those come from the wide build), then the
	# wide build's full install; the terminfo data is not packaged here; usr/include/ncursesw/ links
	make -C obj install.libs
	rm -f "$RAW$LIBDIR"/libtinfo.so* "$RAW$LIBDIR"/libtic.so*
	install -m 644 obj/man/ncurses6-config.1 obj-wide/man
	make -C obj-wide install
	rm -f "$RAW$LIBDIR/libcurses.so"
	install -d "$RAW$INCDIR/ncursesw"
	local f
	for f in "$RAW$INCDIR"/*.h; do ln -s "../${f##*/}" "$RAW$INCDIR/ncursesw"; done
	# install-arch: the static libraries; libncurses.so and libncursesw.so as linker scripts
	install -m 644 -t "$RAW$LIBDIR" obj-static/lib/*.a obj-wide-static/lib/*.a
	rm -f "$RAW$LIBDIR/libncurses.so" "$RAW$LIBDIR/libncursesw.so"
	echo "INPUT(libncurses.so.6 -ltinfo)" > "$RAW$LIBDIR/libncurses.so"
	echo "INPUT(libncursesw.so.6 -ltinfo)" > "$RAW$LIBDIR/libncursesw.so"
	# debian/libncurses-dev.links
	ln -s libncurses.so "$RAW$LIBDIR/libcurses.so"
	ln -s libncurses.a "$RAW$LIBDIR/libcurses.a"
	ln -s libtinfo.so "$RAW$LIBDIR/libtermcap.so"
	ln -s libtinfo.a "$RAW$LIBDIR/libtermcap.a"
}
