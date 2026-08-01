#!/bin/sh
# Build the release tarball for 微读 (wereaddesktop.koplugin).
#
# The plugin's self-updater (updater.lua) downloads the .tar.gz asset
# attached to a GitHub release, extracts it into a staging directory,
# validates it, and then replaces the live plugin directory. The tarball
# MUST therefore have wereaddesktop.koplugin/ as its single top-level entry.
#
# Usage (from the repo root):
#   sh tools/release.sh            # -> dist/wereaddesktop.koplugin-v<version>.tar.gz
#
# Then create a GitHub release tagged v<version> and attach the tarball.

set -eu

cd "$(dirname "$0")/.."

VERSION=$(luajit -e 'package.path = package.path .. ";wereaddesktop.koplugin/?.lua"; print(require("wereaddesktop_version"))' 2>/dev/null) \
    || VERSION=$(sed -n 's/^return "\(.*\)"$/\1/p' wereaddesktop.koplugin/wereaddesktop_version.lua)
if [ -z "$VERSION" ]; then
    echo "could not read version from wereaddesktop.koplugin/wereaddesktop_version.lua" >&2
    exit 1
fi

OUT_DIR="dist"
OUT="$OUT_DIR/wereaddesktop.koplugin-v$VERSION.tar.gz"
TMP_OUT="$OUT.tmp"
mkdir -p "$OUT_DIR"
trap 'rm -f "$TMP_OUT"' 0 1 2 15

# Refuse to ship AppleDouble metadata files (e.g. ._* leftovers from
# cloud-synced folders or zip extraction). They are not part of the plugin
# and would either bloat the package or be silently dropped on install.
if find wereaddesktop.koplugin -name '._*' -print -quit | grep -q .; then
    echo "source contains AppleDouble ._* files, refusing to build" >&2
    exit 1
fi

# COPYFILE_DISABLE=1 stops macOS bsdtar from generating ._* entries for
# files carrying extended attributes (the plugin sources have
# com.apple.provenance xattrs). Harmless on GNU tar / CI.
COPYFILE_DISABLE=1 tar -czf "$TMP_OUT" wereaddesktop.koplugin

# Post-build layout check: every entry must live inside the plugin root.
# The updater rejects any tarball with entries outside it, so fail here
# before a release can be published.
if ! tar -tzf "$TMP_OUT" | awk '
    /^wereaddesktop\.koplugin\/?$/ || /^wereaddesktop\.koplugin\// { next }
    { print; bad = 1 }
    END { exit bad }
'; then
    echo "release tarball contains entries outside wereaddesktop.koplugin/:" >&2
    exit 1
fi

mv "$TMP_OUT" "$OUT"

echo "built $OUT"
echo "next: tag v$VERSION on GitHub, create a release, attach this file"
