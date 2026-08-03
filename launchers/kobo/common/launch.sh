#!/bin/sh

KOREADER_SCRIPT="/mnt/onboard/.adds/koreader/koreader.sh"
PLUGIN_MAIN="/mnt/onboard/.adds/koreader/plugins/wereaddesktop.koplugin/main.lua"
LOG_FILE="/mnt/onboard/.adds/weread/launcher.log"

launcher_error() {
    mkdir -p "${LOG_FILE%/*}"
    printf '%s\n' "$1" > "$LOG_FILE"
    return 1
}

[ -x "$KOREADER_SCRIPT" ] \
    || launcher_error "找不到 $KOREADER_SCRIPT，请先安装完整 KOReader。" \
    || exit 1
[ -f "$PLUGIN_MAIN" ] \
    || launcher_error "找不到微读插件，请先安装 wereaddesktop.koplugin。" \
    || exit 1

rm -f "$LOG_FILE"

# 不使用 exec：KFMon 模式下让 KOReader 由此脚本间接启动，退出时按普通
# Nickel 启动路径恢复 Kobo 桌面，同时 KFMon 仍会等待整个阅读进程结束。
"$KOREADER_SCRIPT"
