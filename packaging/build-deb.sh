#!/usr/bin/env bash
# Build a Debian package without needing a debian/ directory.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

VERSION=${VERSION:-$(sed -n 's/^VERSION="\(.*\)"/\1/p' organize.sh)}
ARCH=${ARCH:-$(dpkg --print-architecture)}
PKG=organize
MAINTAINER=${MAINTAINER:-hollali <dheztinykartel@gmail.com>}

command -v dpkg-deb >/dev/null 2>&1 || {
	echo "dpkg-deb not found" >&2
	exit 1
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root=$stage/${PKG}_${VERSION}_${ARCH}
mkdir -p "$root/DEBIAN"

make install DESTDIR="$root" PREFIX=/usr

installed_kb=$(du -sk "$root" | cut -f1)

cat >"$root/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Installed-Size: $installed_kb
Depends: bash (>= 4.0), coreutils, findutils
Maintainer: $MAINTAINER
Homepage: https://github.com/hollali/file-organizer
Description: sort files and folders into category folders
 organize.sh groups files by type, recognises TV episodes, series, movies
 and music, detects duplicates, and records every move in an undoable log.
EOF

mkdir -p dist
dpkg-deb --build --root-owner-group "$root" "dist/${PKG}_${VERSION}_${ARCH}.deb"
echo "Built dist/${PKG}_${VERSION}_${ARCH}.deb"
