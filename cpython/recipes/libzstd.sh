# libzstd 1.5.7+dfsg-1: debian/rules (dh with the top-level Makefile; DPKG_EXPORT_BUILDTOOLS=1,
# PREFIX=/usr; execute_after_dh_auto_configure: cmake configure of build/cmake for the cmake package files;
# override_dh_auto_install: libdir=/usr/lib/<multiarch>) for arm64
MAINT="hardening=+all"
export PREFIX=/usr
recipe_build() {
	# execute_after_dh_auto_configure: dh_auto_configure --buildsystem=cmake (obj-<triplet>), only for
	# zstdConfig*.cmake and zstdTargets*.cmake (libzstd-dev.install)
	mkdir -p "obj-$T"
	(cd "obj-$T" && cmake ../build/cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=None \
		-DCMAKE_INSTALL_SYSCONFDIR=/etc -DCMAKE_INSTALL_LOCALSTATEDIR=/var -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
		-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON \
		-DFETCHCONTENT_FULLY_DISCONNECTED=ON -DCMAKE_INSTALL_RUNSTATEDIR=/run -DCMAKE_SKIP_INSTALL_ALL_DEPENDENCY=ON \
		"-GUnix Makefiles" -DCMAKE_VERBOSE_MAKEFILE=ON -DCMAKE_INSTALL_LIBDIR=libilp32 \
		-DCMAKE_INSTALL_INCLUDEDIR="$T/include" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
		-DCMAKE_LIBRARY_ARCHITECTURE="$T" -DZSTD_LEGACY_SUPPORT:BOOL=ON -DBUILD_TESTING:BOOL=ON)
	# dh_auto_build: make (the default target) with dh's exported tools and flags
	make -j"$J" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"
}
# dh_auto_test: make test (the first of test/check that exists), Debian's patches limit its memory and time
recipe_check() {
	make test CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"
}
# rules: dh_auto_install -- libdir=/usr/lib/<multiarch>; libzstd-dev.install takes the cmake files from obj-*
recipe_install() {
	make install DESTDIR="$RAW" AM_UPDATE_INFO_DIR=no libdir="$LIBDIR" includedir="$INCDIR" \
		CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"
	mkdir -p "$RAW$LIBDIR/cmake/zstd"
	cp "obj-$T"/zstdConfig*.cmake "$RAW$LIBDIR/cmake/zstd/"
	cp "obj-$T"/CMakeFiles/Export/*/zstdTargets*.cmake "$RAW$LIBDIR/cmake/zstd/"
}
