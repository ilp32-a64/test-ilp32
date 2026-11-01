# zlib 1:1.3.dfsg+really1.3.1-1: debian/rules configure-stamp, build-stamp and install for arm64 (no
# biarch flavours on arm64; minizip is built by Debian but not part of the set)
MAINT=
# rules: CFLAGS = dpkg CFLAGS + CPPFLAGS + -Wall -D_REENTRANT, + -O3 (no noopt); LDFLAGS = dpkg LDFLAGS;
# AR=ar for a native build -> the ILP32 binutils' ar
recipe_build() {
	AR=$AR CC=$CC CFLAGS="$CFLAGS $CPPFLAGS -Wall -D_REENTRANT -O3" LDFLAGS="$LDFLAGS" uname=GNU \
		./configure --shared --prefix=/usr --libdir='${prefix}/libilp32' \
		--includedir='${prefix}/aarch64-linux-gnu_ilp32/include'
	make -j"$J"
}
# rules: -$(MAKE) test (failures ignored)
CHECK_IGNORE_FAILURE=1
recipe_check() {
	make test
}
# rules: $(MAKE) prefix=$(CURDIR)/debian/tmp/usr install
recipe_install() {
	make prefix="$RAW/usr" install
}
