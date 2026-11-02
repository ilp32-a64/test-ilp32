# readline 8.2-6: debian/rules (configure-stamp, build-stamp, install-stamp) for arm64; the udeb, biarch and
# rlfe builds are not part of the set
MAINT=
# rules: CFLAGS = dpkg CFLAGS + -I/usr/include/ncursesw (here the ILP32 ncursesw directory)
rl_cflags() { echo "$CFLAGS -I$INCDIR/ncursesw"; }
recipe_build() {
	# configure-stamp: Debian's config.guess/config.sub into support/, configure in build/
	cp -p /usr/share/misc/config.* ./support/
	rm -rf build
	mkdir build
	find . -type d | xargs chmod g-s
	chmod +x configure
	(cd build && CC="$CC" CFLAGS="$(rl_cflags)" CPPFLAGS="$CPPFLAGS" ../configure --prefix=/usr --host="$T" \
		--libdir="$LIBDIR" --includedir="$INCDIR")
	make -j"$J" -C build CFLAGS="$(rl_cflags)" CPPFLAGS="$CPPFLAGS" SHOBJ_CFLAGS="-fPIC -D_REENTRANT" \
		SHOBJ_LDFLAGS="$LDFLAGS -shared" SHLIB_LIBS="-ltinfo"
}
# install-stamp: make install into debian/tmp, then the package layout: lib{history,readline}.so.* (runtime);
# .so links, .a, readline.pc and the headers (dev), chardefs.h without its HAVE_CONFIG_H block
recipe_install() {
	make -C build install CFLAGS="$(rl_cflags)" CPPFLAGS="$CPPFLAGS -D_REENTRANT" \
		SHOBJ_LDFLAGS="-shared $LDFLAGS" SHLIB_XLDFLAGS='-Wl,-soname,`echo $@ | sed s/\\..$$//`' \
		SHLIB_LIBS=-ltinfo DESTDIR="$RAW" mandir=/usr/share/man infodir=/usr/share/info
	rm -f "$RAW$LIBDIR/libhistory.so" "$RAW$LIBDIR/libreadline.so"
	ln -s libhistory.so.8 "$RAW$LIBDIR/libhistory.so"
	ln -s libreadline.so.8 "$RAW$LIBDIR/libreadline.so"
	local h=$RAW$INCDIR/readline/chardefs.h
	awk '/^#if defined \(HAVE_CONFIG_H\)/, /^#endif/ {if ($0 == "#else") print "#include <string.h>"; next} {print}' \
		"$h" > "$h.new"
	if diff -u "$h" "$h.new"; then rm -f "$h.new"; else mv -f "$h.new" "$h"; fi
}
