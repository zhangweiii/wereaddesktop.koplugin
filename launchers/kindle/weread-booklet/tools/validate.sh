#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALLER_DIR="$LAUNCHER_DIR/../installer"

sh -n "$LAUNCHER_DIR/install/install.sh"
sh -n "$LAUNCHER_DIR/uninstall/uninstall.sh"
sh -n "$SCRIPT_DIR/build.sh"
sh -n "$INSTALLER_DIR/install.sh"
sh -n "$INSTALLER_DIR/spec/test_install.sh"
node --check "$SCRIPT_DIR/patch-kol-class.mjs"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
    "$LAUNCHER_DIR/install/extensions/weread/menu.json"

grep -q "com.github.zhangweiii.wereadlauncher" \
    "$LAUNCHER_DIR/install/appreg.install.sql"
grep -q "com.github.zhangweiii.wereadlauncher" \
    "$LAUNCHER_DIR/uninstall/appreg.uninstall.sql"
grep -q "/mnt/us/documents/微信读书.weread" \
    "$LAUNCHER_DIR/install/install.sh"
grep -q "/mnt/us/documents/微信读书.weread" \
    "$LAUNCHER_DIR/uninstall/uninstall.sh"
grep -q "5.12.2 或更高" "$INSTALLER_DIR/install.sh"
grep -q "/Volumes/Kindle" "$INSTALLER_DIR/install.sh"
grep -q "/media/\*/Kindle" "$INSTALLER_DIR/install.sh"
grep -q "/\[d-z\]" "$INSTALLER_DIR/install.sh"

sh "$INSTALLER_DIR/spec/test_install.sh"

echo "weread-booklet 静态校验通过"
