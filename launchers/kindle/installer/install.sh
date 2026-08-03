#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
PLUGIN_SOURCE="$PAYLOAD_DIR/wereaddesktop.koplugin"
STANDARD_PACKAGE="$PAYLOAD_DIR/Update_WeReadBooklet_install.bin"
HOTFIX_PACKAGE="$PAYLOAD_DIR/Update_WeReadBooklet_hotfix_install.bin"
UNINSTALL_PACKAGE="$PAYLOAD_DIR/Update_WeReadBooklet_uninstall.bin"

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

is_kindle_root() {
    [ -f "$1/koreader/koreader.sh" ] \
        && [ -d "$1/koreader/plugins" ] \
        && [ -d "$1/mrpackages" ]
}

validate_kindle_root() {
    [ -d "$1" ] || fail "Kindle 路径不存在：$1"
    [ -f "$1/koreader/koreader.sh" ] \
        || fail "未找到完整 KOReader：$1/koreader/koreader.sh"
    [ -d "$1/koreader/plugins" ] \
        || fail "未找到 KOReader 插件目录：$1/koreader/plugins"
    [ -d "$1/mrpackages" ] \
        || fail "未找到 MRPI 的 mrpackages 目录，请先安装 MRPI"
}

detect_kindle_root() {
    if [ -n "${KINDLE_ROOT:-}" ]; then
        normalize_path "$KINDLE_ROOT"
        return
    fi

    for candidate in \
        /Volumes/Kindle \
        /media/*/Kindle \
        /run/media/*/Kindle \
        /mnt/Kindle \
        /mnt/kindle \
        /[d-z] \
        /[D-Z]; do
        if is_kindle_root "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    printf '%s\n' ""
}

prompt_kindle_root() {
    detected_root="$(detect_kindle_root)"
    if [ -n "$detected_root" ]; then
        echo "检测到 Kindle：$detected_root" >&2
        printf '%s\n' "$detected_root"
        return
    fi

    echo "没有自动找到 Kindle。" >&2
    echo "请输入 Kindle 磁盘根目录，例如：" >&2
    echo "  macOS: /Volumes/Kindle" >&2
    echo "  Linux: /media/用户名/Kindle" >&2
    echo "  Windows Git Bash: /d 或 D:/" >&2
    printf '> ' >&2
    IFS= read -r entered_root || fail "未输入 Kindle 路径"
    normalize_path "$entered_root"
}

prompt_action() {
    while :; do
        echo "请选择操作：" >&2
        echo "  1) 安装或升级微读（插件 + Kindle 首页入口）" >&2
        echo "  2) 只卸载 Kindle 首页入口（保留插件、书籍和登录数据）" >&2
        printf '> ' >&2
        IFS= read -r action_choice || fail "未选择操作"
        case "$action_choice" in
            1) printf '%s\n' "install"; return ;;
            2) printf '%s\n' "uninstall"; return ;;
            *) echo "请输入 1 或 2。" >&2 ;;
        esac
    done
}

prompt_firmware_package() {
    while :; do
        echo "请选择 Kindle 固件范围（设置 → 设备选项 → 设备信息）：" >&2
        echo "  1) 5.12.2 或更高（hotfix，绝大多数较新固件）" >&2
        echo "  2) 低于 5.12.2（普通包）" >&2
        printf '> ' >&2
        IFS= read -r firmware_choice || fail "未选择固件范围"
        case "$firmware_choice" in
            1) printf '%s\n' "$HOTFIX_PACKAGE"; return ;;
            2) printf '%s\n' "$STANDARD_PACKAGE"; return ;;
            *) echo "请输入 1 或 2；不知道时请先在 Kindle 上确认固件版本。" >&2 ;;
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
    echo "正在同步文件并安全弹出 Kindle……"
    if eject_device "$1"; then
        echo "Kindle 已安全弹出，可以拔下 USB 连接线。"
    else
        echo "自动弹出 Kindle 失败；安装文件已经复制完成，请从系统中手动安全弹出后再拔线。" >&2
    fi
}

install_plugin() {
    plugins_dir="$1/koreader/plugins"
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

for required in \
    "$PLUGIN_SOURCE/main.lua" \
    "$PLUGIN_SOURCE/_meta.lua" \
    "$STANDARD_PACKAGE" \
    "$HOTFIX_PACKAGE" \
    "$UNINSTALL_PACKAGE"; do
    [ -e "$required" ] || fail "安装包不完整，缺少：$required"
done

echo "微读 Kindle 一键安装器"
echo "Windows 请在解压目录中使用 Git Bash 运行：sh install.sh"
echo

KINDLE_ROOT="$(prompt_kindle_root)"
validate_kindle_root "$KINDLE_ROOT"

ACTION="$(prompt_action)"
if [ "$ACTION" = "install" ]; then
    SELECTED_PACKAGE="$(prompt_firmware_package)"
    echo
    echo "将安装到：$KINDLE_ROOT"
    echo "固件包：$(basename "$SELECTED_PACKAGE")"
    echo "现有微信登录数据和书籍不会被删除。"
    confirm || fail "用户取消安装"

    install_plugin "$KINDLE_ROOT"
    cp "$SELECTED_PACKAGE" "$KINDLE_ROOT/mrpackages/$(basename "$SELECTED_PACKAGE")"
    echo
    echo "电脑端安装准备完成。"
else
    echo
    echo "将把首页入口卸载包复制到：$KINDLE_ROOT/mrpackages"
    echo "微读插件、书籍和登录数据会保留。"
    confirm || fail "用户取消卸载"

    cp "$UNINSTALL_PACKAGE" "$KINDLE_ROOT/mrpackages/$(basename "$UNINSTALL_PACKAGE")"
    echo
    echo "电脑端卸载准备完成。"
fi

finish_and_eject "$KINDLE_ROOT"
echo "接下来，请在 Kindle 的 KUAL → Helper+ → Install MR Packages 中执行一次。"
