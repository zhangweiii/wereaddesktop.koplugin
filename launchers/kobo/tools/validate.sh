#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$LAUNCHER_DIR/../.." && pwd)"
VERSION="$(sed -n 's/^return "\(.*\)"$/\1/p' "$PROJECT_DIR/wereaddesktop.koplugin/wereaddesktop_version.lua")"
INSTALLER_DIR="$LAUNCHER_DIR/installer"

sh -n "$LAUNCHER_DIR/common/launch.sh"
sh -n "$SCRIPT_DIR/build.sh"
sh -n "$INSTALLER_DIR/install.sh"
sh -n "$INSTALLER_DIR/spec/test_install.sh"

grep -Fq "menu_item :main :微信读书 :cmd_spawn :quiet:/bin/sh /mnt/onboard/.adds/weread/launch.sh" \
    "$LAUNCHER_DIR/nickelmenu/weread"
grep -Fq "filename = /mnt/onboard/微信读书.png" \
    "$LAUNCHER_DIR/kfmon/weread.ini"
grep -Fq "action = /mnt/onboard/.adds/weread/launch.sh" \
    "$LAUNCHER_DIR/kfmon/weread.ini"
grep -Fq "/mnt/onboard/.adds/koreader/koreader.sh" \
    "$LAUNCHER_DIR/common/launch.sh"
grep -Fq "/Volumes/KOBOeReader" "$INSTALLER_DIR/install.sh"
grep -Fq "NickelMenu 菜单入口" "$INSTALLER_DIR/install.sh"
grep -Fq "KFMon 首页/书库封面入口" "$INSTALLER_DIR/install.sh"

if awk 'length($0) > 200 { print NR ":" $0; bad = 1 } END { exit bad }' \
    "$LAUNCHER_DIR/kfmon/weread.ini"; then
    :
else
    echo "KFMon 配置存在超过 200 字节的行" >&2
    exit 1
fi

VALIDATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/weread-kobo-validate.XXXXXX")"
cleanup() {
    rm -rf "$VALIDATE_TMP"
}
trap cleanup EXIT HUP INT TERM

OUT_DIR="$VALIDATE_TMP" sh "$SCRIPT_DIR/build.sh" >/dev/null

INSTALLER_ZIP="$VALIDATE_TMP/WeRead_Kobo_Installer_v${VERSION}.zip"
test "$(find "$VALIDATE_TMP" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 1
unzip -tq "$INSTALLER_ZIP" >/dev/null
unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "install.sh"
unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "payload/launch.sh"
unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "payload/nickelmenu-weread"
unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "payload/kfmon-weread.ini"
unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "payload/wereaddesktop.koplugin/main.lua"

UNZIP_LOCALE=""
for candidate in C.UTF-8 en_US.UTF-8 zh_CN.UTF-8; do
    if [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)" = "UTF-8" ]; then
        UNZIP_LOCALE="$candidate"
        break
    fi
done
[ -n "$UNZIP_LOCALE" ]
LC_ALL="$UNZIP_LOCALE" unzip -Z1 "$INSTALLER_ZIP" | grep -Fxq "payload/微信读书.png"

sh "$INSTALLER_DIR/spec/test_install.sh"

echo "Kobo 启动器静态与打包校验通过"
