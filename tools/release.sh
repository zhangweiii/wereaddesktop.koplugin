#!/bin/sh
# Build the release tarball for 微读 (wereaddesktop.koplugin).
#
# The plugin's self-updater (updater.lua) downloads the .tar.gz asset
# attached to a GitHub release and unpacks it over the plugins/
# directory, so the tarball MUST have wereaddesktop.koplugin/ as its
# single top-level entry.
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
mkdir -p "$OUT_DIR"

tar -czf "$OUT" wereaddesktop.koplugin

echo "built $OUT"
echo "next: tag v$VERSION on GitHub, create a release, attach this file"
