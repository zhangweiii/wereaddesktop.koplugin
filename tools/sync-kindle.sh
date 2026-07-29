#!/bin/sh
# 将本地 wereaddesktop.koplugin 同步到 Kindle
# 用法: sh tools/sync-kindle.sh
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/wereaddesktop.koplugin"

# 自动检测 Kindle 挂载点
PLUGINS_DIR=""
DEST=""
for d in /Volumes/Kindle /Volumes/KOBOeReader; do
    if [ -d "$d/koreader/plugins" ]; then
        PLUGINS_DIR="$d/koreader/plugins"
        DEST="$PLUGINS_DIR/wereaddesktop.koplugin"
        break
    fi
done

if [ -z "$DEST" ]; then
    echo "找不到 Kindle/KOBO 设备，请确认已通过 USB 连接。" >&2
    exit 1
fi

STAGING="$PLUGINS_DIR/.wereaddesktop_sync_staging"
BACKUP="$PLUGINS_DIR/.wereaddesktop_sync_backup"
rollback_needed=0

if [ -e "$BACKUP" ]; then
    if [ -e "$DEST" ]; then
        rm -rf "$BACKUP"
    else
        mv "$BACKUP" "$DEST"
    fi
fi
if [ -e "$STAGING" ]; then
    rm -rf "$STAGING"
fi

cleanup() {
    status="$1"
    trap - EXIT HUP INT TERM
    if [ "$rollback_needed" -eq 1 ] \
        && [ ! -e "$DEST" ] && [ -e "$BACKUP" ]; then
        mv "$BACKUP" "$DEST" || true
    fi
    if [ -e "$STAGING" ]; then
        rm -rf "$STAGING"
    fi
    exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 1' HUP INT TERM

echo "同步到临时目录: $SRC -> $STAGING"
cp -R "$SRC" "$STAGING"
for required in main.lua _meta.lua wereaddesktop_version.lua; do
    if [ ! -f "$STAGING/$required" ]; then
        echo "同步校验失败，缺少: $required" >&2
        exit 1
    fi
done

if [ -e "$DEST" ]; then
    mv "$DEST" "$BACKUP"
    rollback_needed=1
fi
if ! mv "$STAGING" "$DEST"; then
    echo "启用新插件失败，正在恢复旧插件。" >&2
    exit 1
fi
rollback_needed=0
if [ -e "$BACKUP" ]; then
    rm -rf "$BACKUP"
fi

trap - EXIT HUP INT TERM
echo "同步完成。"

# 弹出设备
VOL=$(echo "$DEST" | awk -F/ '{print $3}')
[ -n "$VOL" ] && diskutil eject "/Volumes/$VOL" 2>/dev/null && echo "已弹出 $VOL。" && exit 0
true
