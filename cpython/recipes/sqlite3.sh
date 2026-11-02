# sqlite3 3.46.1-7+deb13u2: debian/rules (configure-stamp, build-stamp, install) for arm64; no test step in the
# rules. The tcl binding (no ILP32 tcl), the icu.so and csv.so extensions (csv.so is not packaged by Debian
# either) and the programs (sqlite3, show*, sqldiff, sqlite3_analyzer, lemon) are not part of the set.
MAINT="hardening=+all future=+lfs"
sq_flags() {
	LDFLAGS="$LDFLAGS -Wl,--as-needed"
	CFLAGS="$CFLAGS -O2 -fno-strict-aliasing \
		-DSQLITE_SECURE_DELETE -DSQLITE_ENABLE_COLUMN_METADATA \
		-DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS \
		-DSQLITE_ENABLE_RTREE=1 -DSQLITE_SOUNDEX=1 \
		-DSQLITE_ENABLE_UNLOCK_NOTIFY \
		-DSQLITE_ENABLE_DBSTAT_VTAB \
		-DSQLITE_ENABLE_DBPAGE_VTAB \
		-DSQLITE_ALLOW_ROWID_IN_VIEW \
		-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1 \
		-DSQLITE_ENABLE_LOAD_EXTENSION \
		-DSQLITE_ENABLE_JSON1 \
		-DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
		-DSQLITE_THREADSAFE=1 \
		-DSQLITE_ENABLE_FTS3_TOKENIZER=1 \
		-DSQLITE_USE_URI=1 \
		-DSQLITE_MAX_SCHEMA_RETRY=25 \
		-DSQLITE_ENABLE_PREUPDATE_HOOK \
		-DSQLITE_ENABLE_SESSION \
		-DSQLITE_ENABLE_STMTVTAB \
		-DSQLITE_STRICT_SUBTYPE=1 \
		-DSQLITE_MAX_VARIABLE_NUMBER=250000"
	export CFLAGS LDFLAGS
}
recipe_build() {
	sq_flags
	# configure-stamp: dh_autoreconf --as-needed, dh_update_autotools_config, configure, the sqlite3.pc fix
	dh_autoreconf --as-needed
	update_autotools_config
	./configure --prefix=/usr --mandir=/usr/share/man --host="$T" --disable-tcl --enable-threadsafe \
		--enable-load-extension --enable-json --enable-fts4 --enable-fts5 --disable-amalgamation \
		--libdir="$LIBDIR" --includedir="$INCDIR" --libexecdir="$LIBDIR/sqlite3" SHELL=/bin/sh
	sed -i "s/\([-ldl .+]\) -ldl/\1/" sqlite3.pc
	make -j"$J"
}
recipe_install() {
	sq_flags
	make install DESTDIR="$RAW"
}
