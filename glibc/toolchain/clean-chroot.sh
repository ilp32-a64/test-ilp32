#!/bin/bash
# Clean build chroots for release builds (compilibary), sbuild style: a pristine Debian 13 arm64 base
# tarball (debootstrap --variant=buildd, nothing of ours), a fresh copy for each release build,
# thrown away afterwards.
#   clean-chroot.sh base                      create base/trixie-arm64-buildd.tar.zst (+ .sha256, .dpkg-l)
#   clean-chroot.sh fresh <name>              unpack a fresh copy to fresh/<name> (checks the base's sha256)
#   clean-chroot.sh run <name> <cmd...>       run a command in it (/proc, /dev, /dev/pts and a tmpfs on
#                                             /dev/shm mounted meanwhile, as sbuild does)
#   clean-chroot.sh destroy <name>            unmount and delete fresh/<name>
set -euo pipefail
W=/srv/build/compilibary
BASE=$W/base/trixie-arm64-buildd.tar.zst
MIRROR=http://deb.debian.org/debian

mounted() { local o; o=$(findmnt -rn -o TARGET); grep -qx "$1" <<< "$o"; }	# (no pipe: pipefail)
umount_all() { # <chroot>: never lazily (that would cut /dev and /proc away from a running user)
	local m
	for m in "$1/dev/shm" "$1/dev/pts" "$1/dev" "$1/proc"; do
		if mounted "$m"; then umount "$m" || { echo "cannot unmount $m (in use)"; return 1; }; fi
	done
}
run_in() { # <chroot> <cmd...>: one run per chroot at a time
	local c=$1 rc m; shift
	for m in "$c/proc" "$c/dev" "$c/dev/pts" "$c/dev/shm"; do
		if mounted "$m"; then echo "$c is in use by another run ($m is mounted)"; return 1; fi
	done
	trap "umount_all '$c'" EXIT
	mount -t proc proc "$c/proc"
	mount --bind /dev "$c/dev"
	mount --bind /dev/pts "$c/dev/pts"
	# the bind mount of /dev does not carry the host's /dev/shm tmpfs: an own one, writable by all
	mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$c/dev/shm"
	set +e
	chroot "$c" /usr/bin/env -i HOME=/root LANG=C.UTF-8 TERM=dumb \
		PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin "$@"
	rc=$?
	set -e
	umount_all "$c"
	return $rc
}

case ${1:-} in
base)
	[ ! -e "$BASE" ] || { echo "$BASE exists"; exit 1; }
	R=$W/base/root
	rm -rf "$R"; mkdir -p "$W/base"
	debootstrap --variant=buildd --arch=arm64 trixie "$R" "$MIRROR"
	cat > "$R/etc/apt/sources.list.d/debian.sources" <<-EOF
		Types: deb deb-src
		URIs: $MIRROR
		Suites: trixie trixie-updates
		Components: main
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

		Types: deb deb-src
		URIs: http://security.debian.org/debian-security
		Suites: trixie-security
		Components: main
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
	EOF
	rm -f "$R/etc/apt/sources.list"
	cp /etc/resolv.conf "$R/etc/resolv.conf"
	run_in "$R" /bin/sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && apt-get clean'
	run_in "$R" dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' > "$BASE.dpkg-l"
	tar -C "$R" --numeric-owner -cf - . | zstd -q -T4 -19 -o "$BASE"
	sha256sum "$BASE" | sed "s|$W/base/||" > "$BASE.sha256"
	rm -rf "$R"
	ls -la "$W/base"; wc -l < "$BASE.dpkg-l"
	;;
fresh)
	n=${2:?name}; c=$W/fresh/$n
	[ ! -e "$c" ] || { echo "$c exists"; exit 1; }
	(cd "$W/base" && sha256sum -c "$(basename "$BASE").sha256")
	mkdir -p "$c"
	zstd -q -d -c "$BASE" | tar -C "$c" --numeric-owner -xf -
	echo "fresh chroot $c from $(cut -c1-16 "$BASE.sha256")"
	;;
run)
	n=${2:?name}; shift 2
	run_in "$W/fresh/$n" "$@"
	;;
destroy)
	n=${2:?name}; c=$W/fresh/$n
	umount_all "$c"
	o=$(findmnt -rn -o TARGET); if grep -q "^$c/" <<< "$o"; then echo "still mounted in $c"; exit 1; fi
	rm -rf --one-file-system "$c"
	echo "destroyed $c"
	;;
*)
	echo "usage: $0 base | fresh <name> | run <name> <cmd...> | destroy <name>"; exit 1 ;;
esac
