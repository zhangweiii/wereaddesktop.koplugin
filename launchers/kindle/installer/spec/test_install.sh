#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALLER_SOURCE="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/weread-installer-test.XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

prepare_case() {
    case_dir="$1"
    mkdir -p \
        "$case_dir/bundle/payload/wereaddesktop.koplugin" \
        "$case_dir/kindle/koreader/plugins/wereaddesktop.koplugin" \
        "$case_dir/kindle/mrpackages" \
        "$case_dir/kindle/settings"
    cp "$INSTALLER_SOURCE/install.sh" "$case_dir/bundle/install.sh"
    touch "$case_dir/bundle/payload/wereaddesktop.koplugin/main.lua"
    touch "$case_dir/bundle/payload/wereaddesktop.koplugin/_meta.lua"
    touch "$case_dir/bundle/payload/Update_WeReadBooklet_install.bin"
    touch "$case_dir/bundle/payload/Update_WeReadBooklet_hotfix_install.bin"
    touch "$case_dir/bundle/payload/Update_WeReadBooklet_uninstall.bin"
    touch "$case_dir/kindle/koreader/koreader.sh"
    touch "$case_dir/kindle/koreader/plugins/wereaddesktop.koplugin/stale.lua"
    printf '%s\n' "keep-login" > "$case_dir/kindle/settings/weread.lua"
}

HOTFIX_CASE="$TEST_TMP/hotfix"
prepare_case "$HOTFIX_CASE"
printf '1\n1\ny\n' | KINDLE_ROOT="$HOTFIX_CASE/kindle" \
    WEREAD_EJECT_OS=Test \
    sh "$HOTFIX_CASE/bundle/install.sh" >/dev/null 2>&1
test -f "$HOTFIX_CASE/kindle/koreader/plugins/wereaddesktop.koplugin/main.lua"
test ! -e "$HOTFIX_CASE/kindle/koreader/plugins/wereaddesktop.koplugin/stale.lua"
test -f "$HOTFIX_CASE/kindle/mrpackages/Update_WeReadBooklet_hotfix_install.bin"
grep -Fqx "keep-login" "$HOTFIX_CASE/kindle/settings/weread.lua"

STANDARD_CASE="$TEST_TMP/standard"
prepare_case "$STANDARD_CASE"
printf '1\n2\ny\n' | KINDLE_ROOT="$STANDARD_CASE/kindle" \
    WEREAD_EJECT_OS=Test \
    sh "$STANDARD_CASE/bundle/install.sh" >/dev/null 2>&1
test -f "$STANDARD_CASE/kindle/mrpackages/Update_WeReadBooklet_install.bin"
test ! -e "$STANDARD_CASE/kindle/mrpackages/Update_WeReadBooklet_hotfix_install.bin"

UNINSTALL_CASE="$TEST_TMP/uninstall"
prepare_case "$UNINSTALL_CASE"
printf '2\ny\n' | KINDLE_ROOT="$UNINSTALL_CASE/kindle" \
    WEREAD_EJECT_OS=Test \
    sh "$UNINSTALL_CASE/bundle/install.sh" >"$UNINSTALL_CASE/output.log" 2>&1
test -f "$UNINSTALL_CASE/kindle/mrpackages/Update_WeReadBooklet_uninstall.bin"
test -f "$UNINSTALL_CASE/kindle/koreader/plugins/wereaddesktop.koplugin/stale.lua"
grep -Fqx "keep-login" "$UNINSTALL_CASE/kindle/settings/weread.lua"
grep -Fq "自动弹出 Kindle 失败" "$UNINSTALL_CASE/output.log"

WINDOWS_CASE="$TEST_TMP/windows path"
prepare_case "$WINDOWS_CASE"
mkdir -p "$WINDOWS_CASE/bin"
printf '#!/bin/sh\nif [ "$1" = "-w" ]; then\n    echo "D:"\nelse\n    printf "%%s\\n" "%s"\nfi\n' "$WINDOWS_CASE/kindle" \
    > "$WINDOWS_CASE/bin/cygpath"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$EJECT_LOG"\n' \
    > "$WINDOWS_CASE/bin/powershell.exe"
chmod +x "$WINDOWS_CASE/bin/cygpath"
chmod +x "$WINDOWS_CASE/bin/powershell.exe"
printf '1\n1\ny\n' | PATH="$WINDOWS_CASE/bin:$PATH" KINDLE_ROOT='D:\Kindle' \
    WEREAD_EJECT_OS=MINGW64_NT EJECT_LOG="$WINDOWS_CASE/eject.log" \
    sh "$WINDOWS_CASE/bundle/install.sh" >"$WINDOWS_CASE/output.log" 2>&1
test -f "$WINDOWS_CASE/kindle/mrpackages/Update_WeReadBooklet_hotfix_install.bin"
grep -Fq "\$drive='D:'" "$WINDOWS_CASE/eject.log"
grep -Fq "Test-Path" "$WINDOWS_CASE/eject.log"
grep -Fq "Kindle 已安全弹出" "$WINDOWS_CASE/output.log"

MACOS_CASE="$TEST_TMP/macos"
prepare_case "$MACOS_CASE"
mkdir -p "$MACOS_CASE/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$EJECT_LOG"\n' \
    > "$MACOS_CASE/bin/diskutil"
chmod +x "$MACOS_CASE/bin/diskutil"
printf '1\n1\ny\n' | PATH="$MACOS_CASE/bin:$PATH" \
    KINDLE_ROOT="$MACOS_CASE/kindle" WEREAD_EJECT_OS=Darwin \
    EJECT_LOG="$MACOS_CASE/eject.log" \
    sh "$MACOS_CASE/bundle/install.sh" >"$MACOS_CASE/output.log" 2>&1
grep -Fqx "eject $MACOS_CASE/kindle" "$MACOS_CASE/eject.log"
grep -Fq "Kindle 已安全弹出" "$MACOS_CASE/output.log"

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
printf '1\n1\ny\n' | PATH="$LINUX_CASE/bin:$PATH" \
    KINDLE_ROOT="$LINUX_CASE/kindle" WEREAD_EJECT_OS=Linux \
    EJECT_LOG="$LINUX_CASE/eject.log" \
    sh "$LINUX_CASE/bundle/install.sh" >"$LINUX_CASE/output.log" 2>&1
grep -Fqx "unmount -b /dev/sdz1" "$LINUX_CASE/eject.log"
grep -Fqx "power-off -b /dev/sdz" "$LINUX_CASE/eject.log"
grep -Fq "Kindle 已安全弹出" "$LINUX_CASE/output.log"

echo "Kindle 一键安装器测试通过"
