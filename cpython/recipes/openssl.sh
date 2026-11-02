# openssl 3.5.7-1~deb13u3: debian/rules (dh --without autoreconf; override_dh_auto_configure,
# -build-arch, -test-arch, -install-arch) for arm64 (no OPT_arm64 flavours), with Debian's own ILP32 target
# debian-arm64ilp32 (Configurations/20-debian.conf: linux-arm64ilp32 + debian)
MAINT="hardening=+all future=+lfs"
# rules' CONFARGS (arm64: enable-ec_nistp_64_gcc_128, no-padlockeng); --libdir relative to the prefix
CONFARGS="--prefix=/usr --openssldir=/usr/lib/ssl --libdir=libilp32 no-idea no-mdc2 no-rc5 no-ssl3 enable-unit-test
	no-ssl3-method enable-rfc3779 enable-cms no-capieng no-rdrand enable-tfo enable-zstd enable-zlib enable-fips
	enable-ec_nistp_64_gcc_128 no-padlockeng"
recipe_build() {
	# override_dh_auto_configure: Configure in build_shared (dh exports the dpkg-buildflags; CC the ILP32 gcc)
	mkdir build_shared
	# shellcheck disable=SC2086
	(cd build_shared && HASHBANGPERL=/usr/bin/perl ../Configure shared $CONFARGS debian-arm64ilp32 && perl configdata.pm -d)
	# override_dh_auto_build-arch
	ln -sf apps/openssl.pod crypto/crypto.pod ssl/ssl.pod doc/
	make -j"$J" -C build_shared all
}
# override_dh_auto_test-arch
recipe_check() {
	make -j"$J" -C build_shared test HARNESS_VERBOSE=yes
}
# override_dh_auto_install-arch: install, the static libraries, (the /etc/ssl moves belong to Debian's openssl
# package), the headers: Debian moves opensslconf.h and configuration.h to usr/include/<multiarch>/openssl;
# here all headers go to the one ILP32 include directory, and the .pc/cmake files point there
recipe_install() {
	make -C build_shared install DESTDIR="$RAW"
	cp -pf build_shared/libcrypto.a "$RAW$LIBDIR/libcrypto.a"
	cp -pf build_shared/libssl.a "$RAW$LIBDIR/libssl.a"
	cp -auv build_shared/lib*.so* "$RAW$LIBDIR/"
	mkdir -p "$RAW$INCDIR"
	mv "$RAW/usr/include/openssl" "$RAW$INCDIR/"
	rmdir "$RAW/usr/include"
	sed -i "s|^includedir=.*|includedir=$INCDIR|" "$RAW$LIBDIR"/pkgconfig/*.pc
	grep -l '/include' "$RAW$LIBDIR"/cmake/OpenSSL/*.cmake | while read -r f; do
		sed -i 's|\${_ossl_prefix}/include|${_ossl_prefix}/aarch64-linux-gnu_ilp32/include|g' "$f"
	done
}
