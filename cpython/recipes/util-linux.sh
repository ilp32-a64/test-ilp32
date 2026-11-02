# util-linux 2.41.5-0+deb13u1: debian/rules (dh; override_dh_autoreconf, override_dh_auto_configure,
# override_dh_auto_install) for arm64, but only libuuid (libuuid1, uuid-dev): the rest of util-linux (programs,
# libblkid, libmount, ...) is not part of the set and would need ILP32 libselinux, libsystemd, libudev, libaudit,
# libpam, libcap-ng, libcryptsetup
MAINT="hardening=+bindnow"
recipe_build() {
	# override_dh_autoreconf: AM_OPTS=--copy LT_OPTS=--copy dh_autoreconf ./autogen.sh
	update_autotools_config
	AM_OPTS=--copy LT_OPTS=--copy ./autogen.sh
	# dh_auto_configure's arguments for the triplet; of Debian's CONFOPTS only what applies to libuuid
	./configure --host="$T" --prefix=/usr --includedir="$INCDIR" --mandir=/usr/share/man \
		--infodir=/usr/share/info --sysconfdir=/etc --localstatedir=/var --disable-option-checking \
		--disable-silent-rules --libdir="$LIBDIR" --runstatedir=/run --disable-maintainer-mode \
		--disable-dependency-tracking --enable-usrdir-path --disable-makeinstall-chown \
		--disable-all-programs --enable-libuuid --without-python --without-systemd --without-udev \
		--without-selinux --without-smack --without-audit --without-cryptsetup --disable-bash-completion
	make -j"$J"
}
# dh_auto_test --max-parallel=1 (make check: here the tests of what is built)
recipe_check() {
	make check
}
# override_dh_auto_install: dh_auto_install, all static libraries removed but libuuid.a and libblkid.a
recipe_install() {
	make install DESTDIR="$RAW" AM_UPDATE_INFO_DIR=no
	find "$RAW/usr" -name 'lib*.a' \! -name 'libuuid.a' \! -name 'libblkid.a' -delete -print
}
