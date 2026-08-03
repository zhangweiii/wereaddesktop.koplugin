#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$LAUNCHER_DIR/../.." && pwd)"
INSTALLER_SOURCE_DIR="$LAUNCHER_DIR/installer"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist}"
VERSION="$(sed -n 's/^return "\(.*\)"$/\1/p' "$PROJECT_DIR/wereaddesktop.koplugin/wereaddesktop_version.lua")"

[ -n "$VERSION" ] || {
    echo "无法读取插件版本号" >&2
    exit 1
}
command -v zip >/dev/null 2>&1 || {
    echo "缺少 zip" >&2
    exit 1
}

ZIP_LOCALE=""
for candidate in C.UTF-8 en_US.UTF-8 zh_CN.UTF-8; do
    if [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)" = "UTF-8" ]; then
        ZIP_LOCALE="$candidate"
        break
    fi
done
[ -n "$ZIP_LOCALE" ] || {
    echo "找不到可用的 UTF-8 locale，无法安全打包中文封面文件名" >&2
    exit 1
}

INSTALLER_OUT="$OUT_DIR/WeRead_Kobo_Installer_v${VERSION}.zip"

if [ -e "$INSTALLER_OUT" ]; then
    echo "拒绝覆盖已有文件: $INSTALLER_OUT" >&2
    exit 1
fi

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/weread-kobo.XXXXXX")"
cleanup() {
    rm -rf "$BUILD_TMP"
}
trap cleanup EXIT HUP INT TERM

INSTALLER_DIR="$BUILD_TMP/installer"

if find "$PROJECT_DIR/wereaddesktop.koplugin" -name '._*' -print -quit | grep -q .; then
    echo "插件源码包含 AppleDouble ._* 文件，拒绝打包" >&2
    exit 1
fi

mkdir -p "$INSTALLER_DIR/payload" "$OUT_DIR"
cp "$INSTALLER_SOURCE_DIR/install.sh" "$INSTALLER_DIR/install.sh"
cp "$INSTALLER_SOURCE_DIR/README.txt" "$INSTALLER_DIR/README.txt"
cp -R "$PROJECT_DIR/wereaddesktop.koplugin" \
    "$INSTALLER_DIR/payload/wereaddesktop.koplugin"
cp "$LAUNCHER_DIR/common/launch.sh" "$INSTALLER_DIR/payload/launch.sh"
cp "$LAUNCHER_DIR/nickelmenu/weread" "$INSTALLER_DIR/payload/nickelmenu-weread"
cp "$LAUNCHER_DIR/kfmon/weread.ini" "$INSTALLER_DIR/payload/kfmon-weread.ini"
cp "$PROJECT_DIR/screenshots/shelf.png" "$INSTALLER_DIR/payload/微信读书.png"
chmod +x "$INSTALLER_DIR/install.sh" "$INSTALLER_DIR/payload/launch.sh"

(cd "$INSTALLER_DIR" && LC_ALL="$ZIP_LOCALE" zip -q -r "$INSTALLER_OUT" .)

echo "已生成："
echo "  $INSTALLER_OUT"
