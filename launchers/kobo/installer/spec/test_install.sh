#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALLER_SOURCE="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/weread-kobo-installer-test.XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

prepare_case() {
    case_dir="$1"
    mkdir -p \
        "$case_dir/bundle/payload/wereaddesktop.koplugin" \
        "$case_dir/kobo/.adds/koreader/plugins/wereaddesktop.koplugin" \
        "$case_dir/kobo/.adds/nm" \
        "$case_dir/kobo/.adds/kfmon/config" \
        "$case_dir/kobo/.adds/weread" \
        "$case_dir/kobo/settings"
    cp "$INSTALLER_SOURCE/install.sh" "$case_dir/bundle/install.sh"
    touch "$case_dir/bundle/payload/wereaddesktop.koplugin/main.lua"
    touch "$case_dir/bundle/payload/wereaddesktop.koplugin/_meta.lua"
    touch "$case_dir/bundle/payload/launch.sh"
    touch "$case_dir/bundle/payload/nickelmenu-weread"
    touch "$case_dir/bundle/payload/kfmon-weread.ini"
    touch "$case_dir/bundle/payload/微信读书.png"
    touch "$case_dir/kobo/.adds/koreader/koreader.sh"
    touch "$case_dir/kobo/.adds/koreader/plugins/wereaddesktop.koplugin/stale.lua"
    touch "$case_dir/kobo/.adds/nm/weread"
    touch "$case_dir/kobo/.adds/kfmon/config/weread.ini"
    touch "$case_dir/kobo/.adds/weread/launch.sh"
    touch "$case_dir/kobo/微信读书.png"
    printf '%s\n' "keep-login" > "$case_dir/kobo/settings/weread.lua"
}

NICKELMENU_CASE="$TEST_TMP/nickelmenu"
prepare_case "$NICKELMENU_CASE"
printf '1\ny\n' | KOBO_ROOT="$NICKELMENU_CASE/kobo" \
    WEREAD_EJECT_OS=Test \
    sh "$NICKELMENU_CASE/bundle/install.sh" >/dev/null 2>&1
test -f "$NICKELMENU_CASE/kobo/.adds/nm/weread"
test ! -e "$NICKELMENU_CASE/kobo/.adds/kfmon/config/weread.ini"
test ! -e "$NICKELMENU_CASE/kobo/微信读书.png"
test ! -e "$NICKELMENU_CASE/kobo/.adds/koreader/plugins/wereaddesktop.koplugin/stale.lua"
grep -Fqx "keep-login" "$NICKELMENU_CASE/kobo/settings/weread.lua"

KFMON_CASE="$TEST_TMP/kfmon"
prepare_case "$KFMON_CASE"
printf '2\ny\n' | KOBO_ROOT="$KFMON_CASE/kobo" \
    WEREAD_EJECT_OS=Test \
    sh "$KFMON_CASE/bundle/install.sh" >/dev/null 2>&1
test -f "$KFMON_CASE/kobo/.adds/kfmon/config/weread.ini"
test -f "$KFMON_CASE/kobo/微信读书.png"
test ! -e "$KFMON_CASE/kobo/.adds/nm/weread"

UNINSTALL_CASE="$TEST_TMP/uninstall"
prepare_case "$UNINSTALL_CASE"
printf '3\ny\n' | KOBO_ROOT="$UNINSTALL_CASE/kobo" \
    WEREAD_EJECT_OS=Test \
    sh "$UNINSTALL_CASE/bundle/install.sh" >"$UNINSTALL_CASE/output.log" 2>&1
test ! -e "$UNINSTALL_CASE/kobo/.adds/nm/weread"
test ! -e "$UNINSTALL_CASE/kobo/.adds/kfmon/config/weread.ini"
test ! -e "$UNINSTALL_CASE/kobo/.adds/weread/launch.sh"
test ! -e "$UNINSTALL_CASE/kobo/微信读书.png"
test -f "$UNINSTALL_CASE/kobo/.adds/koreader/plugins/wereaddesktop.koplugin/stale.lua"
grep -Fqx "keep-login" "$UNINSTALL_CASE/kobo/settings/weread.lua"
grep -Fq "自动弹出 Kobo 失败" "$UNINSTALL_CASE/output.log"

WINDOWS_CASE="$TEST_TMP/windows path"
prepare_case "$WINDOWS_CASE"
mkdir -p "$WINDOWS_CASE/bin"
printf '#!/bin/sh\nif [ "$1" = "-w" ]; then\n    echo "E:"\nelse\n    printf "%%s\\n" "%s"\nfi\n' "$WINDOWS_CASE/kobo" \
    > "$WINDOWS_CASE/bin/cygpath"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$EJECT_LOG"\n' \
    > "$WINDOWS_CASE/bin/powershell.exe"
chmod +x "$WINDOWS_CASE/bin/cygpath"
chmod +x "$WINDOWS_CASE/bin/powershell.exe"
printf '1\ny\n' | PATH="$WINDOWS_CASE/bin:$PATH" KOBO_ROOT='E:\KOBOeReader' \
    WEREAD_EJECT_OS=MINGW64_NT EJECT_LOG="$WINDOWS_CASE/eject.log" \
    sh "$WINDOWS_CASE/bundle/install.sh" >"$WINDOWS_CASE/output.log" 2>&1
test -f "$WINDOWS_CASE/kobo/.adds/nm/weread"
grep -Fq "\$drive='E:'" "$WINDOWS_CASE/eject.log"
grep -Fq "Test-Path" "$WINDOWS_CASE/eject.log"
grep -Fq "Kobo 已安全弹出" "$WINDOWS_CASE/output.log"

MACOS_CASE="$TEST_TMP/macos"
prepare_case "$MACOS_CASE"
mkdir -p "$MACOS_CASE/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$EJECT_LOG"\n' \
    > "$MACOS_CASE/bin/diskutil"
chmod +x "$MACOS_CASE/bin/diskutil"
printf '1\ny\n' | PATH="$MACOS_CASE/bin:$PATH" \
    KOBO_ROOT="$MACOS_CASE/kobo" WEREAD_EJECT_OS=Darwin \
    EJECT_LOG="$MACOS_CASE/eject.log" \
    sh "$MACOS_CASE/bundle/install.sh" >"$MACOS_CASE/output.log" 2>&1
grep -Fqx "eject $MACOS_CASE/kobo" "$MACOS_CASE/eject.log"
grep -Fq "Kobo 已安全弹出" "$MACOS_CASE/output.log"

LINUX_CASE="$TEST_TMP/linux"
prepare_case "$LINUX_CASE"
mkdir -p "$LINUX_CASE/bin"
printf '#!/bin/sh\nexit 0\n' > "$LINUX_CASE/bin/mountpoint"
printf '#!/bin/sh\necho "/dev/sdz1"\n' > "$LINUX_CASE/bin/findmnt"
printf '#!/bin/sh\necho "sdz"\n' > "$LINUX_CASE/bin/lsblk"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$EJECT_LOG"\n' \
    > "$LINUX_CASE/bin/udisksctl"
chmod +x \
    "$LINUX_CASE/bin/mountpoint" \
    "$LINUX_CASE/bin/findmnt" \
    "$LINUX_CASE/bin/lsblk" \
    "$LINUX_CASE/bin/udisksctl"
printf '1\ny\n' | PATH="$LINUX_CASE/bin:$PATH" \
    KOBO_ROOT="$LINUX_CASE/kobo" WEREAD_EJECT_OS=Linux \
    EJECT_LOG="$LINUX_CASE/eject.log" \
    sh "$LINUX_CASE/bundle/install.sh" >"$LINUX_CASE/output.log" 2>&1
grep -Fqx "unmount -b /dev/sdz1" "$LINUX_CASE/eject.log"
grep -Fqx "power-off -b /dev/sdz" "$LINUX_CASE/eject.log"
grep -Fq "Kobo 已安全弹出" "$LINUX_CASE/output.log"

echo "Kobo 一键安装器测试通过"
