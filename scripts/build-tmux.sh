#!/bin/sh
# 从源码编译 App 内置用的通用（arm64 + x86_64）tmux：libevent 与 utf8proc 静态链接，
# 只动态链接每台 Mac 都有的系统 libncurses / libSystem；部署目标 macOS 14。
# 结果缓存在 build/tmux/ 下，版本或校验和不变时不重新编译。成功时最后一行输出 tmux 路径。
set -eu
cd "$(dirname "$0")/.."

# 版本与 SHA-256 固定（与 Homebrew formula 记录的校验和一致；libevent 为官方发布包）。
# tmux 停在 3.6a：3.7 系列在 macOS 上需要 jemalloc 才能避开进入复制模式时的断言崩溃（tmux issue 5385），
# 而滚轮翻看历史正是靠复制模式；3.6a 用系统 malloc，没有这个断言。
TMUX_VERSION=3.6a
TMUX_SHA256=b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759
TMUX_URL="https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
LIBEVENT_VERSION=2.1.12-stable
LIBEVENT_SHA256=92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"
UTF8PROC_VERSION=2.12.0
UTF8PROC_SHA256=f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111
UTF8PROC_URL="https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$UTF8PROC_VERSION.tar.gz"
MIN_MACOS=14.0

ROOT="$PWD/build/tmux"
OUT="$ROOT/tmux-$TMUX_VERSION+libevent-$LIBEVENT_VERSION+utf8proc-$UTF8PROC_VERSION"
if [ -x "$OUT/tmux" ] && [ -f "$OUT/LICENSES.txt" ]; then
    echo "$OUT/tmux"
    exit 0
fi

SRC="$ROOT/src"
mkdir -p "$SRC"

# 下载（已下载则复用）并校验 SHA-256；不匹配时删除并失败。
fetch() {
    url="$1"; sha="$2"; file="$SRC/$3"
    if [ ! -f "$file" ]; then
        echo "下载 $url" >&2
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
        echo "校验和不匹配：$file（期望 $sha，实际 $actual）" >&2
        rm -f "$file"
        exit 1
    fi
}

fetch "$TMUX_URL" "$TMUX_SHA256" "tmux-$TMUX_VERSION.tar.gz"
fetch "$LIBEVENT_URL" "$LIBEVENT_SHA256" "libevent-$LIBEVENT_VERSION.tar.gz"
fetch "$UTF8PROC_URL" "$UTF8PROC_SHA256" "utf8proc-$UTF8PROC_VERSION.tar.gz"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
WORK="$ROOT/work"
rm -rf "$WORK"
mkdir -p "$WORK"

for ARCH in arm64 x86_64; do
    case "$ARCH" in
        arm64) HOST=aarch64-apple-darwin ;;
        x86_64) HOST=x86_64-apple-darwin ;;
    esac
    A="$WORK/$ARCH"
    PREFIX="$A/prefix"
    mkdir -p "$A" "$PREFIX/include" "$PREFIX/lib"
    CC="$(xcrun --find clang) -arch $ARCH"
    CFLAGS="-O2 -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"
    CPPFLAGS="-isysroot $SDK"
    LDFLAGS="-isysroot $SDK -mmacosx-version-min=$MIN_MACOS"
    export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

    # utf8proc：只要静态库与头文件。
    tar -xzf "$SRC/utf8proc-$UTF8PROC_VERSION.tar.gz" -C "$A"
    (cd "$A/utf8proc-$UTF8PROC_VERSION" && make -s CC="$CC" CFLAGS="$CFLAGS" libutf8proc.a >&2)
    cp "$A/utf8proc-$UTF8PROC_VERSION/libutf8proc.a" "$PREFIX/lib/"
    cp "$A/utf8proc-$UTF8PROC_VERSION/utf8proc.h" "$PREFIX/include/"

    # libevent：只编译静态库，不需要 OpenSSL。
    tar -xzf "$SRC/libevent-$LIBEVENT_VERSION.tar.gz" -C "$A"
    (cd "$A/libevent-$LIBEVENT_VERSION" \
        && ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --enable-static \
            --disable-openssl --disable-samples --disable-libevent-regress --disable-debug-mode \
            CC="$CC" CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" >&2 \
        && make -s -j"$JOBS" >&2 && make -s install >&2)

    # tmux：用 *_CFLAGS / *_LIBS 直接指定静态库，不依赖 pkg-config；ncurses 用系统动态库。
    tar -xzf "$SRC/tmux-$TMUX_VERSION.tar.gz" -C "$A"
    (cd "$A/tmux-$TMUX_VERSION" \
        && ./configure --host="$HOST" --enable-utf8proc --disable-dependency-tracking \
            CC="$CC" CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" \
            LIBEVENT_CORE_CFLAGS="-I$PREFIX/include" LIBEVENT_CORE_LIBS="$PREFIX/lib/libevent_core.a" \
            LIBEVENT_CFLAGS="-I$PREFIX/include" LIBEVENT_LIBS="$PREFIX/lib/libevent_core.a" \
            LIBUTF8PROC_CFLAGS="-I$PREFIX/include" LIBUTF8PROC_LIBS="$PREFIX/lib/libutf8proc.a" \
            LIBNCURSES_CFLAGS="" LIBNCURSES_LIBS="-lncurses" \
            LIBTINFO_CFLAGS="" LIBTINFO_LIBS="-lncurses" >&2 \
        && make -s -j"$JOBS" >&2)
    cp "$A/tmux-$TMUX_VERSION/tmux" "$A/tmux"
done

STAGE="$ROOT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
lipo -create "$WORK/arm64/tmux" "$WORK/x86_64/tmux" -output "$STAGE/tmux"
strip -x "$STAGE/tmux"

# 校验：两种架构、不链接 Homebrew / 构建目录里的库、能运行。
lipo -info "$STAGE/tmux" >&2
lipo "$STAGE/tmux" -verify_arch arm64 x86_64
otool -L -arch all "$STAGE/tmux" >&2
if otool -L -arch all "$STAGE/tmux" | grep -E '^[[:space:]]' | grep -v -E '^[[:space:]]+(/usr/lib/|/System/Library/)' >&2; then
    echo "tmux 链接了非系统库" >&2
    exit 1
fi
"$STAGE/tmux" -V >&2
arch -x86_64 "$STAGE/tmux" -V >&2 || echo "（无 Rosetta，跳过 x86_64 运行检查）" >&2

# 许可证文本（tmux: ISC；libevent: 3-clause BSD；utf8proc: MIT）。
{
    echo "CC Desk 内置的 tmux 及其静态链接的库"
    echo
    echo "==== tmux $TMUX_VERSION (https://github.com/tmux/tmux) ===="
    cat "$WORK/arm64/tmux-$TMUX_VERSION/COPYING"
    echo
    echo "==== libevent $LIBEVENT_VERSION (https://libevent.org) ===="
    cat "$WORK/arm64/libevent-$LIBEVENT_VERSION/LICENSE"
    echo
    echo "==== utf8proc $UTF8PROC_VERSION (https://github.com/JuliaStrings/utf8proc) ===="
    cat "$WORK/arm64/utf8proc-$UTF8PROC_VERSION/LICENSE.md"
} > "$STAGE/LICENSES.txt"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
rm -rf "$WORK"
echo "$OUT/tmux"
