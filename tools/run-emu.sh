#!/bin/sh
# 启动 KOReader 模拟器，Kindle 3:4 长宽比（1072×1448）
set -eu

EMU_DIR="${EMU_DIR:-$HOME/work/koreader/koreader-emulator-arm64-apple-darwin23.6.0-debug/koreader}"
PLUGIN_DIR="$EMU_DIR/plugins/wereaddesktop.koplugin"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$EMU_DIR" ]; then
    echo "模拟器目录不存在: $EMU_DIR" >&2
    exit 1
fi

# 安装/更新插件
echo "[*] 安装插件..."
rm -rf "$PLUGIN_DIR"
cp -r "$PROJECT_DIR/wereaddesktop.koplugin" "$PLUGIN_DIR"

# 确保 settings 目录存在
mkdir -p "$EMU_DIR/settings"

# 开启 debug 截图：桌面出现后自动截屏到 screenshots/ 目录
mkdir -p "$EMU_DIR/screenshots"
if [ -f "$EMU_DIR/settings/reader.lua" ]; then
    # 已有 reader.lua，提示手动添加
    echo "[*] 开启自动截图请在 $EMU_DIR/settings/reader.lua 中添加:"
    echo '    ["wereaddesktop_debug_screenshot"] = true,'
else
    echo 'return { ["wereaddesktop_debug_screenshot"] = true }' > "$EMU_DIR/settings/reader.lua"
    echo "[*] debug 截图已开启"
fi

echo "[*] 启动模拟器 (1072×1448)..."
cd "$EMU_DIR"
EMULATE_READER_W=1072 EMULATE_READER_H=1448 ./luajit reader.lua
