#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
PLUGIN_SOURCE="$PAYLOAD_DIR/wereaddesktop.koplugin"
LAUNCH_SCRIPT_SOURCE="$PAYLOAD_DIR/launch.sh"
NICKELMENU_SOURCE="$PAYLOAD_DIR/nickelmenu-weread"
KFMON_SOURCE="$PAYLOAD_DIR/kfmon-weread.ini"
KFMON_COVER_SOURCE="$PAYLOAD_DIR/微信读书.png"

fail() {
    echo "错误：$1" >&2
    exit 1
}

normalize_path() {
    input_path="$1"
    case "$input_path" in
        [A-Za-z]:*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -u "$input_path"
                return
            fi
            if command -v wslpath >/dev/null 2>&1; then
                wslpath -u "$input_path"
                return
            fi
            ;;
    esac
    printf '%s\n' "${input_path%/}"
}

is_kobo_root() {
    [ -f "$1/.adds/koreader/koreader.sh" ] \
        && [ -d "$1/.adds/koreader/plugins" ]
}

validate_kobo_root() {
    [ -d "$1" ] || fail "Kobo 路径不存在：$1"
    [ -f "$1/.adds/koreader/koreader.sh" ] \
        || fail "未找到完整 KOReader：$1/.adds/koreader/koreader.sh"
    [ -d "$1/.adds/koreader/plugins" ] \
        || fail "未找到 KOReader 插件目录：$1/.adds/koreader/plugins"
}

detect_kobo_root() {
    if [ -n "${KOBO_ROOT:-}" ]; then
        normalize_path "$KOBO_ROOT"
        return
    fi

    for candidate in \
        /Volumes/KOBOeReader \
        /media/*/KOBOeReader \
        /run/media/*/KOBOeReader \
        /mnt/KOBOeReader \
        /mnt/kobo \
        /[d-z] \
        /[D-Z]; do
        if is_kobo_root "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    printf '%s\n' ""
}

prompt_kobo_root() {
    detected_root="$(detect_kobo_root)"
    if [ -n "$detected_root" ]; then
        echo "检测到 Kobo：$detected_root" >&2
        printf '%s\n' "$detected_root"
        return
    fi

    echo "没有自动找到 Kobo。" >&2
    echo "请输入 Kobo 磁盘根目录，例如：" >&2
    echo "  macOS: /Volumes/KOBOeReader" >&2
    echo "  Linux: /media/用户名/KOBOeReader" >&2
    echo "  Windows Git Bash: /e 或 E:/" >&2
    printf '> ' >&2
    IFS= read -r entered_root || fail "未输入 Kobo 路径"
    normalize_path "$entered_root"
}

prompt_mode() {
    while :; do
        echo "请选择操作：" >&2
        echo "  1) 安装或升级：NickelMenu 菜单入口" >&2
        echo "  2) 安装或升级：KFMon 首页/书库封面入口" >&2
        echo "  3) 只卸载微读启动入口（保留插件、书籍和登录数据）" >&2
        printf '> ' >&2
        IFS= read -r mode_choice || fail "未选择操作"
        case "$mode_choice" in
            1) printf '%s\n' "nickelmenu"; return ;;
            2) printf '%s\n' "kfmon"; return ;;
            3) printf '%s\n' "uninstall"; return ;;
            *) echo "请输入 1、2 或 3。" >&2 ;;
        esac
    done
}

confirm() {
    printf '继续吗？[y/N] ' >&2
    IFS= read -r answer || return 1
    case "$answer" in
        y|Y|yes|YES|Yes|是) return 0 ;;
        *) return 1 ;;
    esac
}

windows_drive_for_path() {
    eject_windows_path=""
    if command -v cygpath >/dev/null 2>&1; then
        eject_windows_path="$(cygpath -w "$1" 2>/dev/null || true)"
    elif command -v wslpath >/dev/null 2>&1; then
        eject_windows_path="$(wslpath -w "$1" 2>/dev/null || true)"
    fi

    case "$eject_windows_path" in
        [A-Za-z]:*) printf '%s:\n' "${eject_windows_path%%:*}" ;;
        *) return 1 ;;
    esac
}

eject_windows() {
    eject_drive="$(windows_drive_for_path "$1")" || return 1
    eject_command="\$drive='$eject_drive'; \$item=(New-Object -ComObject Shell.Application).Namespace(17).ParseName(\$drive); if (\$null -eq \$item) { exit 1 }; \$item.InvokeVerb('Eject'); Start-Sleep -Milliseconds 1500; if (Test-Path (\$drive + '\\')) { exit 1 }"

    for eject_powershell in powershell.exe pwsh.exe powershell pwsh; do
        if command -v "$eject_powershell" >/dev/null 2>&1; then
            "$eject_powershell" -NoProfile -NonInteractive -Command \
                "$eject_command" >/dev/null 2>&1
            return $?
        fi
    done
    return 1
}

eject_linux() {
    eject_source=""
    if command -v mountpoint >/dev/null 2>&1 \
        && mountpoint -q "$1" >/dev/null 2>&1 \
        && command -v findmnt >/dev/null 2>&1; then
        eject_source="$(findmnt -n -o SOURCE --target "$1" 2>/dev/null || true)"
    fi

    if [ -n "$eject_source" ] && command -v udisksctl >/dev/null 2>&1; then
        if udisksctl unmount -b "$eject_source" >/dev/null 2>&1; then
            eject_parent=""
            if command -v lsblk >/dev/null 2>&1; then
                eject_parent="$(lsblk -no PKNAME "$eject_source" 2>/dev/null | sed -n '1p')"
            fi
            if [ -n "$eject_parent" ]; then
                udisksctl power-off -b "/dev/$eject_parent" >/dev/null 2>&1 || true
            else
                udisksctl power-off -b "$eject_source" >/dev/null 2>&1 || true
            fi
            return 0
        fi
    fi

    if command -v gio >/dev/null 2>&1 \
        && gio mount -u "$1" >/dev/null 2>&1; then
        return 0
    fi
    if command -v umount >/dev/null 2>&1 \
        && umount "$1" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

eject_device() {
    command -v sync >/dev/null 2>&1 && sync 2>/dev/null || true
    eject_os="${WEREAD_EJECT_OS:-$(uname -s 2>/dev/null || printf '%s' unknown)}"
    case "$eject_os" in
        Darwin)
            command -v diskutil >/dev/null 2>&1 \
                && diskutil eject "$1" >/dev/null 2>&1
            ;;
        MINGW*|MSYS*|CYGWIN*)
            eject_windows "$1"
            ;;
        Linux)
            if command -v wslpath >/dev/null 2>&1 && eject_windows "$1"; then
                return 0
            fi
            eject_linux "$1"
            ;;
        *) return 1 ;;
    esac
}

finish_and_eject() {
    echo "正在同步文件并安全弹出 Kobo……"
    if eject_device "$1"; then
        echo "Kobo 已安全弹出，可以拔下 USB 连接线并重启设备。"
    else
        echo "自动弹出 Kobo 失败；安装文件已经复制完成，请从系统中手动安全弹出后再拔线。" >&2
    fi
}

install_plugin() {
    plugins_dir="$1/.adds/koreader/plugins"
    destination="$plugins_dir/wereaddesktop.koplugin"
    staging="$plugins_dir/.wereaddesktop_install_staging_$$"
    backup="$plugins_dir/.wereaddesktop_install_backup_$$"
    rollback_needed=0

    [ ! -e "$staging" ] || fail "临时目录已存在：$staging"
    [ ! -e "$backup" ] || fail "备份目录已存在：$backup"

    cleanup_install() {
        cleanup_status="$?"
        trap - EXIT HUP INT TERM
        if [ "$rollback_needed" -eq 1 ] \
            && [ ! -e "$destination" ] && [ -e "$backup" ]; then
            mv "$backup" "$destination" || true
        fi
        if [ -e "$staging" ]; then
            rm -rf "$staging"
        fi
        exit "$cleanup_status"
    }
    trap cleanup_install EXIT HUP INT TERM

    echo "正在复制微读插件……"
    cp -R "$PLUGIN_SOURCE" "$staging"
    [ -f "$staging/main.lua" ] || fail "插件复制后缺少 main.lua"
    [ -f "$staging/_meta.lua" ] || fail "插件复制后缺少 _meta.lua"

    if [ -e "$destination" ]; then
        mv "$destination" "$backup"
        rollback_needed=1
    fi
    if ! mv "$staging" "$destination"; then
        fail "启用新插件失败，旧插件将自动恢复"
    fi

    rollback_needed=0
    if [ -e "$backup" ]; then
        rm -rf "$backup"
    fi
    trap - EXIT HUP INT TERM
}

install_common_launcher() {
    mkdir -p "$1/.adds/weread"
    cp "$LAUNCH_SCRIPT_SOURCE" "$1/.adds/weread/launch.sh"
    chmod +x "$1/.adds/weread/launch.sh" 2>/dev/null || true
}

install_nickelmenu() {
    [ -d "$1/.adds/nm" ] \
        || fail "未检测到 NickelMenu，请先安装 NickelMenu"
    install_common_launcher "$1"
    cp "$NICKELMENU_SOURCE" "$1/.adds/nm/weread"
    rm -f "$1/.adds/kfmon/config/weread.ini" "$1/微信读书.png"
}

install_kfmon() {
    [ -d "$1/.adds/kfmon/config" ] \
        || fail "未检测到 KFMon，请先安装 KFMon"
    install_common_launcher "$1"
    cp "$KFMON_SOURCE" "$1/.adds/kfmon/config/weread.ini"
    cp "$KFMON_COVER_SOURCE" "$1/微信读书.png"
    rm -f "$1/.adds/nm/weread"
}

uninstall_launchers() {
    rm -f \
        "$1/.adds/nm/weread" \
        "$1/.adds/kfmon/config/weread.ini" \
        "$1/.adds/weread/launch.sh" \
        "$1/微信读书.png"
    rmdir "$1/.adds/weread" 2>/dev/null || true
}

for required in \
    "$PLUGIN_SOURCE/main.lua" \
    "$PLUGIN_SOURCE/_meta.lua" \
    "$LAUNCH_SCRIPT_SOURCE" \
    "$NICKELMENU_SOURCE" \
    "$KFMON_SOURCE" \
    "$KFMON_COVER_SOURCE"; do
    [ -e "$required" ] || fail "安装包不完整，缺少：$required"
done

echo "微读 Kobo 一键安装器"
echo "Windows 请在解压目录中使用 Git Bash 运行：sh install.sh"
echo

KOBO_ROOT="$(prompt_kobo_root)"
validate_kobo_root "$KOBO_ROOT"
MODE="$(prompt_mode)"

echo
echo "将操作设备：$KOBO_ROOT"
case "$MODE" in
    nickelmenu) echo "启动模式：NickelMenu" ;;
    kfmon) echo "启动模式：KFMon 书籍封面" ;;
    uninstall) echo "操作：卸载微读启动入口，保留微读插件" ;;
esac
echo "现有微信登录数据和书籍不会被删除。"
confirm || fail "用户取消操作"

case "$MODE" in
    nickelmenu)
        [ -d "$KOBO_ROOT/.adds/nm" ] \
            || fail "未检测到 NickelMenu，请先安装 NickelMenu"
        install_plugin "$KOBO_ROOT"
        install_nickelmenu "$KOBO_ROOT"
        ;;
    kfmon)
        [ -d "$KOBO_ROOT/.adds/kfmon/config" ] \
            || fail "未检测到 KFMon，请先安装 KFMon"
        install_plugin "$KOBO_ROOT"
        install_kfmon "$KOBO_ROOT"
        ;;
    uninstall)
        uninstall_launchers "$KOBO_ROOT"
        ;;
esac

echo
echo "安装器操作完成。"
finish_and_eject "$KOBO_ROOT"
