#!/bin/sh
# 一次生成 GitHub Release 需要的三个最终附件：
#   1. 通用 KOReader 插件包
#   2. Kindle 一键安装包
#   3. Kobo 一键安装包
#
# 用法（仓库根目录）：
#   sh tools/release.sh
#
# 可选环境变量（主要用于离线构建和测试）：
#   OUT_DIR=/path/to/output
#   RELEASE_CACHE_DIR=/path/to/cache
#   KOL_BIN=/path/to/Update_KOLBooklet_v1.5_install.bin
#   KINDLETOOL=/path/to/kindletool

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="$(sed -n 's/^return "\(.*\)"$/\1/p' wereaddesktop.koplugin/wereaddesktop_version.lua)"
[ -n "$VERSION" ] || {
    echo "无法读取 wereaddesktop.koplugin/wereaddesktop_version.lua 中的版本号" >&2
    exit 1
}

OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist}"
CACHE_DIR="${RELEASE_CACHE_DIR:-$PROJECT_DIR/.release-cache}"
PLUGIN_NAME="wereaddesktop.koplugin-v${VERSION}.tar.gz"
KINDLE_NAME="WeRead_Kindle_Installer_v${VERSION}.zip"
KOBO_NAME="WeRead_Kobo_Installer_v${VERSION}.zip"

KOL_URL="https://github.com/yparitcher/KUAL_Booklet/releases/download/v1.5/KOL-v1.5-20250424.tar.xz"
KOL_SHA256="a8a214a1458dca2bfdc51b93410edfdc97f43c58e396f8923e4b42b595e9e3c9"
KINDLETOOL_LINUX_URL="https://github.com/NiLuJe/KindleTool/releases/download/v1.6.6/kindletool_linux-x64.tar.gz"
KINDLETOOL_LINUX_SHA256="8944523a2837b30d653aa57e4fdb2ac48e34502cda7f07c7f31c707a844b21a1"
KINDLETOOL_SOURCE_URL="https://github.com/NiLuJe/KindleTool/archive/c90a5dc74d81943f1642196727f447248e311429.tar.gz"
KINDLETOOL_SOURCE_SHA256="1e8b6ac9df0db66d75b16e94a99da3eb05184da7eabc92612fa86909fe358990"

for release_path in \
    "$OUT_DIR/$PLUGIN_NAME" \
    "$OUT_DIR/$KINDLE_NAME" \
    "$OUT_DIR/$KOBO_NAME"; do
    if { [ -e "$release_path" ] || [ -L "$release_path" ]; } && \
        { [ ! -f "$release_path" ] || [ -L "$release_path" ]; }; then
        echo "发布路径已被非普通文件占用，拒绝覆盖: $release_path" >&2
        exit 1
    fi
done

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/weread-release.XXXXXX")"
BUILD_OUT="$BUILD_ROOT/out"
FINAL_STAGE=""
mkdir -p "$BUILD_OUT" "$CACHE_DIR"

cleanup() {
    if [ -n "$FINAL_STAGE" ] && [ -d "$FINAL_STAGE" ]; then
        rm -rf "$FINAL_STAGE"
    fi
    if [ -d "$BUILD_ROOT" ]; then
        rm -rf "$BUILD_ROOT"
    fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        LC_ALL=C sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        LC_ALL=C shasum -a 256 "$1" | awk '{ print $1 }'
    else
        echo "缺少 sha256sum 或 shasum，无法校验构建依赖" >&2
        return 1
    fi
}

verify_sha256() {
    verify_file="$1"
    verify_expected="$2"
    verify_actual="$(sha256_file "$verify_file")"
    [ "$verify_actual" = "$verify_expected" ]
}

download_cached() {
    download_dest="$1"
    download_url="$2"
    download_sha="$3"

    if [ -f "$download_dest" ] && verify_sha256 "$download_dest" "$download_sha"; then
        echo "使用已校验缓存: $download_dest"
        return 0
    fi

    download_tmp="$BUILD_ROOT/download.tmp"
    echo "下载构建依赖: $download_url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "$download_url" -o "$download_tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$download_tmp" "$download_url"
    else
        echo "缺少 curl 或 wget，无法下载构建依赖" >&2
        return 1
    fi

    if ! verify_sha256 "$download_tmp" "$download_sha"; then
        echo "下载文件的 SHA-256 校验失败: $download_url" >&2
        return 1
    fi
    mv "$download_tmp" "$download_dest"
}

resolve_kol_bin() {
    if [ -n "${KOL_BIN:-}" ]; then
        [ -f "$KOL_BIN" ] || {
            echo "KOL_BIN 指向的文件不存在: $KOL_BIN" >&2
            return 1
        }
        KOL_BIN_PATH="$KOL_BIN"
        return 0
    fi

    kol_archive="$CACHE_DIR/KOL-v1.5-20250424.tar.xz"
    kol_extract="$BUILD_ROOT/kol"
    download_cached "$kol_archive" "$KOL_URL" "$KOL_SHA256"
    mkdir -p "$kol_extract"
    LC_ALL=C tar -xJf "$kol_archive" -C "$kol_extract"
    KOL_BIN_PATH="$kol_extract/Update_KOLBooklet_v1.5_install.bin"
    [ -f "$KOL_BIN_PATH" ] || {
        echo "KOL 归档中缺少普通安装包" >&2
        return 1
    }
}

build_macos_kindletool() {
    for mac_command in brew make cc bash pkg-config; do
        command -v "$mac_command" >/dev/null 2>&1 || {
            echo "macOS 构建 KindleTool 缺少 $mac_command" >&2
            echo "请先安装 Xcode Command Line Tools，并执行: brew install libarchive nettle gmp pkg-config" >&2
            return 1
        }
    done

    archive_prefix="$(brew --prefix libarchive 2>/dev/null)" || {
        echo "缺少 Homebrew libarchive，请执行: brew install libarchive nettle gmp pkg-config" >&2
        return 1
    }
    nettle_prefix="$(brew --prefix nettle 2>/dev/null)" || {
        echo "缺少 Homebrew nettle，请执行: brew install libarchive nettle gmp pkg-config" >&2
        return 1
    }
    gmp_prefix="$(brew --prefix gmp 2>/dev/null)" || {
        echo "缺少 Homebrew gmp，请执行: brew install libarchive nettle gmp pkg-config" >&2
        return 1
    }

    source_archive="$CACHE_DIR/kindletool-c90a5dc74d81943f1642196727f447248e311429.tar.gz"
    source_extract="$BUILD_ROOT/kindletool-source"
    download_cached "$source_archive" "$KINDLETOOL_SOURCE_URL" "$KINDLETOOL_SOURCE_SHA256"
    mkdir -p "$source_extract"
    LC_ALL=C tar -xzf "$source_archive" -C "$source_extract"

    set -- "$source_extract"/*
    [ "$#" -eq 1 ] && [ -d "$1" ] || {
        echo "KindleTool 源码归档布局异常" >&2
        return 1
    }
    source_dir="$1"

    echo "在 macOS 本地编译 KindleTool v1.6.6"
    make_log="$BUILD_ROOT/kindletool-make.log"
    if ! LC_ALL=C \
        PKG_CONFIG_PATH="$archive_prefix/lib/pkgconfig:$nettle_prefix/lib/pkgconfig:$gmp_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CPPFLAGS="-I$archive_prefix/include -I$nettle_prefix/include -I$gmp_prefix/include${CPPFLAGS:+ $CPPFLAGS}" \
        LDFLAGS="-L$archive_prefix/lib -L$nettle_prefix/lib -L$gmp_prefix/lib${LDFLAGS:+ $LDFLAGS}" \
            make -s -C "$source_dir" >"$make_log" 2>&1; then
        echo "KindleTool 编译失败，详细日志如下：" >&2
        cat "$make_log" >&2
        return 1
    fi

    KINDLETOOL_PATH="$source_dir/KindleTool/Release/kindletool"
    [ -x "$KINDLETOOL_PATH" ] || {
        echo "KindleTool 编译完成但没有找到可执行文件" >&2
        return 1
    }
}

resolve_kindletool() {
    if [ -n "${KINDLETOOL:-}" ]; then
        [ -x "$KINDLETOOL" ] || {
            echo "KINDLETOOL 不存在或不可执行: $KINDLETOOL" >&2
            return 1
        }
        KINDLETOOL_PATH="$KINDLETOOL"
    elif command -v kindletool >/dev/null 2>&1; then
        KINDLETOOL_PATH="$(command -v kindletool)"
    else
        host_os="$(uname -s)"
        host_arch="$(uname -m)"
        case "$host_os:$host_arch" in
            Linux:x86_64|Linux:amd64)
                kindletool_archive="$CACHE_DIR/kindletool_linux-x64-v1.6.6.tar.gz"
                kindletool_extract="$BUILD_ROOT/kindletool-linux"
                download_cached "$kindletool_archive" "$KINDLETOOL_LINUX_URL" "$KINDLETOOL_LINUX_SHA256"
                mkdir -p "$kindletool_extract"
                LC_ALL=C tar -xzf "$kindletool_archive" -C "$kindletool_extract"
                KINDLETOOL_PATH="$kindletool_extract/kindletool"
                chmod +x "$KINDLETOOL_PATH"
                ;;
            Darwin:*)
                build_macos_kindletool
                ;;
            *)
                echo "当前系统没有可自动获取的 KindleTool: $host_os $host_arch" >&2
                echo "请通过 KINDLETOOL=/path/to/kindletool 指定本机可执行文件后重试" >&2
                return 1
                ;;
        esac
    fi

    "$KINDLETOOL_PATH" version >/dev/null
}

build_plugin_archive() {
    plugin_out="$BUILD_OUT/$PLUGIN_NAME"

    if find wereaddesktop.koplugin -name '._*' -print -quit | grep -q .; then
        echo "插件源码包含 AppleDouble ._* 文件，拒绝打包" >&2
        return 1
    fi

    COPYFILE_DISABLE=1 LC_ALL=C tar -czf "$plugin_out" wereaddesktop.koplugin
    if ! LC_ALL=C tar -tzf "$plugin_out" | awk '
        /^wereaddesktop\.koplugin\/?$/ || /^wereaddesktop\.koplugin\// { next }
        { print; bad = 1 }
        END { exit bad }
    '; then
        echo "通用插件包包含 wereaddesktop.koplugin/ 之外的条目" >&2
        return 1
    fi
}

echo "[1/5] 校验 Kindle 与 Kobo 启动器"
sh launchers/kindle/weread-booklet/tools/validate.sh
sh launchers/kobo/tools/validate.sh

echo "[2/5] 准备固定版本的 Kindle 构建依赖"
resolve_kol_bin
resolve_kindletool

echo "[3/5] 构建通用 KOReader 插件包"
build_plugin_archive

echo "[4/5] 构建 Kindle 与 Kobo 一键安装包"
OUT_DIR="$BUILD_OUT" sh launchers/kindle/weread-booklet/tools/build.sh \
    "$KOL_BIN_PATH" "$KINDLETOOL_PATH"
OUT_DIR="$BUILD_OUT" sh launchers/kobo/tools/build.sh

echo "[5/5] 校验并发布三个最终文件"
for built_path in \
    "$BUILD_OUT/$PLUGIN_NAME" \
    "$BUILD_OUT/$KINDLE_NAME" \
    "$BUILD_OUT/$KOBO_NAME"; do
    [ -f "$built_path" ] || {
        echo "缺少预期发布文件: $built_path" >&2
        exit 1
    }
done

[ "$(find "$BUILD_OUT" -type f | wc -l | tr -d ' ')" = "3" ] || {
    echo "发布临时目录中不是恰好三个文件，拒绝继续" >&2
    find "$BUILD_OUT" -type f -print >&2
    exit 1
}
LC_ALL=C tar -tzf "$BUILD_OUT/$PLUGIN_NAME" >/dev/null
unzip -tq "$BUILD_OUT/$KINDLE_NAME" >/dev/null
unzip -tq "$BUILD_OUT/$KOBO_NAME" >/dev/null

mkdir -p "$OUT_DIR"
FINAL_STAGE="$(mktemp -d "$OUT_DIR/.weread-release.XXXXXX")"
cp "$BUILD_OUT/$PLUGIN_NAME" "$FINAL_STAGE/$PLUGIN_NAME"
cp "$BUILD_OUT/$KINDLE_NAME" "$FINAL_STAGE/$KINDLE_NAME"
cp "$BUILD_OUT/$KOBO_NAME" "$FINAL_STAGE/$KOBO_NAME"
mv "$FINAL_STAGE/$PLUGIN_NAME" "$OUT_DIR/$PLUGIN_NAME"
mv "$FINAL_STAGE/$KINDLE_NAME" "$OUT_DIR/$KINDLE_NAME"
mv "$FINAL_STAGE/$KOBO_NAME" "$OUT_DIR/$KOBO_NAME"
rmdir "$FINAL_STAGE"
FINAL_STAGE=""

echo "发布构建完成，共 3 个文件："
echo "  $OUT_DIR/$PLUGIN_NAME"
echo "  $OUT_DIR/$KINDLE_NAME"
echo "  $OUT_DIR/$KOBO_NAME"
