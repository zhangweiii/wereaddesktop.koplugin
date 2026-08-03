#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "用法: sh launchers/kindle/weread-booklet/tools/build.sh <KOL普通安装包.bin> <kindletool>" >&2
    exit 2
fi

UPSTREAM_BIN="$1"
KINDLETOOL="$2"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$LAUNCHER_DIR/../../.." && pwd)"
INSTALLER_SOURCE_DIR="$LAUNCHER_DIR/../installer"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist}"
VERSION="$(sed -n 's/^return "\(.*\)"$/\1/p' "$PROJECT_DIR/wereaddesktop.koplugin/wereaddesktop_version.lua")"

[ -n "$VERSION" ] || {
    echo "无法读取插件版本号" >&2
    exit 1
}

[ -f "$UPSTREAM_BIN" ] || {
    echo "找不到 KOL 安装包: $UPSTREAM_BIN" >&2
    exit 1
}
[ -x "$KINDLETOOL" ] || {
    echo "kindletool 不存在或不可执行: $KINDLETOOL" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || {
    echo "缺少 node" >&2
    exit 1
}
command -v unzip >/dev/null 2>&1 || {
    echo "缺少 unzip" >&2
    exit 1
}
command -v zip >/dev/null 2>&1 || {
    echo "缺少 zip" >&2
    exit 1
}

INSTALLER_OUT="$OUT_DIR/WeRead_Kindle_Installer_v${VERSION}.zip"

if [ -e "$INSTALLER_OUT" ]; then
    echo "拒绝覆盖已有文件: $INSTALLER_OUT" >&2
    exit 1
fi

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/weread-booklet.XXXXXX")"
cleanup() {
    rm -rf "$BUILD_TMP"
}
trap cleanup EXIT HUP INT TERM

UPSTREAM_DIR="$BUILD_TMP/upstream"
JAR_DIR="$BUILD_TMP/jar"
INSTALL_DIR="$BUILD_TMP/install"
UNINSTALL_DIR="$BUILD_TMP/uninstall"
INSTALLER_DIR="$BUILD_TMP/installer"
PACKAGE_DIR="$BUILD_TMP/packages"
KINDLETOOL_LOG="$BUILD_TMP/kindletool.log"
INSTALL_OUT="$PACKAGE_DIR/Update_WeReadBooklet_v${VERSION}_install.bin"
HOTFIX_OUT="$PACKAGE_DIR/Update_WeReadBooklet_hotfix_v${VERSION}_install.bin"
UNINSTALL_OUT="$PACKAGE_DIR/Update_WeReadBooklet_v${VERSION}_uninstall.bin"

run_kindletool() {
    if ! "$KINDLETOOL" "$@" >>"$KINDLETOOL_LOG" 2>&1; then
        echo "KindleTool 执行失败，详细日志如下：" >&2
        cat "$KINDLETOOL_LOG" >&2
        exit 1
    fi
}

run_kindletool extract "$UPSTREAM_BIN" "$UPSTREAM_DIR"
[ -f "$UPSTREAM_DIR/KOLBooklet.jar" ] || {
    echo "输入不是预期的 KOL Booklet 普通安装包" >&2
    exit 1
}
[ -f "$UPSTREAM_DIR/libotautils5" ] || {
    echo "KOL 安装包缺少 libotautils5" >&2
    exit 1
}

mkdir -p "$JAR_DIR" "$INSTALL_DIR" "$UNINSTALL_DIR" "$PACKAGE_DIR" "$OUT_DIR"
(cd "$JAR_DIR" && unzip -q "$UPSTREAM_DIR/KOLBooklet.jar")
node "$SCRIPT_DIR/patch-kol-class.mjs" "$JAR_DIR"
(cd "$JAR_DIR" && zip -q -r "$INSTALL_DIR/WeReadBooklet.jar" .)

cp -R "$LAUNCHER_DIR/install/." "$INSTALL_DIR/"
cp -R "$LAUNCHER_DIR/uninstall/." "$UNINSTALL_DIR/"
cp "$UPSTREAM_DIR/libotautils5" "$INSTALL_DIR/libotautils5"
cp "$UPSTREAM_DIR/libotautils5" "$UNINSTALL_DIR/libotautils5"
chmod +x "$INSTALL_DIR/install.sh" "$UNINSTALL_DIR/uninstall.sh"

export KT_WITH_UNKNOWN_DEVCODES=1

run_kindletool create ota2 \
    -xPackageName=WeReadBooklet \
    -xPackageVersion="v${VERSION}" \
    -xPackageAuthor=KOL-Team,zhangweiii \
    -xPackageMaintainer=zhangweiii \
    -X -d kindle5 -s 1679530004 -C "$INSTALL_DIR" "$INSTALL_OUT"

run_kindletool create ota2 \
    -xPackageName=WeReadBooklet \
    -xPackageVersion="v${VERSION}" \
    -xPackageAuthor=KOL-Team,zhangweiii \
    -xPackageMaintainer=zhangweiii \
    -X \
    -d paperwhite2 -d basic -d voyage -d paperwhite3 -d oasis \
    -d basic2 -d oasis2 -d paperwhite4 -d basic3 -d oasis3 \
    -d paperwhite5 -d basic4 -d scribe -d basic5 -d paperwhite6 \
    -d colorsoft \
    -O -s 3556150002 -C "$INSTALL_DIR" "$HOTFIX_OUT"

run_kindletool create ota2 \
    -xPackageName=WeReadBooklet \
    -xPackageVersion="v${VERSION}" \
    -xPackageAuthor=KOL-Team,zhangweiii \
    -xPackageMaintainer=zhangweiii \
    -X -d kindle5 -C "$UNINSTALL_DIR" "$UNINSTALL_OUT"

if find "$PROJECT_DIR/wereaddesktop.koplugin" -name '._*' -print -quit | grep -q .; then
    echo "插件源码包含 AppleDouble ._* 文件，拒绝打包" >&2
    exit 1
fi

mkdir -p "$INSTALLER_DIR/payload"
cp "$INSTALLER_SOURCE_DIR/install.sh" "$INSTALLER_DIR/install.sh"
cp "$INSTALLER_SOURCE_DIR/README.txt" "$INSTALLER_DIR/README.txt"
cp -R "$PROJECT_DIR/wereaddesktop.koplugin" \
    "$INSTALLER_DIR/payload/wereaddesktop.koplugin"
cp "$INSTALL_OUT" "$INSTALLER_DIR/payload/Update_WeReadBooklet_install.bin"
cp "$HOTFIX_OUT" "$INSTALLER_DIR/payload/Update_WeReadBooklet_hotfix_install.bin"
cp "$UNINSTALL_OUT" "$INSTALLER_DIR/payload/Update_WeReadBooklet_uninstall.bin"
chmod +x "$INSTALLER_DIR/install.sh"
(cd "$INSTALLER_DIR" && zip -q -r "$INSTALLER_OUT" .)

echo "已生成："
echo "  $INSTALLER_OUT"
