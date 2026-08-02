#!/bin/sh
# Serve dist/ over the local network for the plugin's hidden local updater.
# Usage: sh tools/serve-update.sh [port] [directory]

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:-8765}"
ROOT="${2:-$PROJECT_DIR/dist}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "找不到 python3，请先安装 Python 3。" >&2
    exit 1
fi
if [ ! -d "$ROOT" ]; then
    echo "目录不存在：$ROOT" >&2
    exit 1
fi

IP=""
if command -v ipconfig >/dev/null 2>&1; then
    for interface in en0 en1; do
        if [ -z "$IP" ]; then
            IP=$(ipconfig getifaddr "$interface" 2>/dev/null || true)
        fi
    done
fi
if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi

SERVE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wereaddesktop-update.XXXXXX")
cleanup() {
    if [ -d "$SERVE_ROOT" ]; then
        rm -rf "$SERVE_ROOT"
    fi
}
trap cleanup EXIT HUP INT TERM

echo "本地升级服务目录：$ROOT"
if [ -n "$IP" ]; then
    echo "电脑地址：http://$IP:$PORT"
fi
found=0
selected=""
for archive in "$ROOT"/wereaddesktop.koplugin-*.tar.gz; do
    if [ -f "$archive" ]; then
        found=1
        if [ -z "$selected" ] || [ "$archive" -nt "$selected" ]; then
            selected="$archive"
        fi
        cp "$archive" "$SERVE_ROOT/$(basename "$archive")"
        echo "升级包地址：http://${IP:-电脑IP}:$PORT/$(basename "$archive")"
    fi
done
if [ "$found" -eq 0 ]; then
    echo "目录中没有 wereaddesktop.koplugin-*.tar.gz，请先运行 sh tools/release.sh。" >&2
    exit 1
else
    cp "$selected" "$SERVE_ROOT/u.tar.gz"
    echo "短地址（指向最近生成的包）：http://${IP:-电脑IP}:$PORT/u.tar.gz"
fi
echo "保持此窗口运行，在 Kindle 的高级升级中输入上面的升级包地址。"
echo "按 Ctrl-C 停止服务。"

python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$SERVE_ROOT"
