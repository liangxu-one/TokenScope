#!/bin/bash
# 构建 TokenScope.app（菜单栏 LLM token 统计工具）
#
# 用法：
#   ./build.sh            编译 + 打包
#   ./build.sh run        编译 + 打包 + 重启应用
#   ./build.sh icon <X>   重新生成图标（X 为方案字母 A~E），然后编译打包
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TokenScope"
APP="${APP_NAME}.app"
BIN=".build/release/${APP_NAME}"
ICON_SRC="icon/AppIcon.png"

# ---------------------------------------------------------------- 图标

# 选择图标方案：./build.sh icon B
if [[ "${1:-}" == "icon" ]]; then
    variant="${2:-B}"
    echo "==> 生成图标方案 $variant"
    (cd icon && swift make_icons.swift . > /dev/null)
    case "$variant" in
        A) src="icon/icon_A_gauge.png" ;;
        B) src="icon/icon_B_bolt_bars.png" ;;
        C) src="icon/icon_C_ring.png" ;;
        D) src="icon/icon_D_scope.png" ;;
        E) src="icon/icon_E_minimal_t.png" ;;
        *) echo "未知方案: $variant（可选 A~E）"; exit 1 ;;
    esac
    cp "$src" "$ICON_SRC"
    echo "    已选用 $src"
    shift 2 2>/dev/null || shift 1
fi

# 由 PNG 生成 .icns
build_icns() {
    [[ -f "$ICON_SRC" ]] || return 1

    local iconset="icon/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"

    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$iconset/icon_${size}x${size}.png" > /dev/null 2>&1
        local double=$((size * 2))
        sips -z $double $double "$ICON_SRC" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null 2>&1
    done

    iconutil -c icns "$iconset" -o "icon/AppIcon.icns" 2>/dev/null
    rm -rf "$iconset"
    [[ -f "icon/AppIcon.icns" ]]
}

# ---------------------------------------------------------------- SDK

# 本机只装了 CommandLineTools、没有 Xcode，默认 SDK（27.x）编不了这个 app：
# 那套 SwiftUI 把 `@State` 改成了宏，宏插件 libSwiftUIMacros 只随 Xcode 发布，
# CLT 里只有 libObservationMacros / libSwiftMacros。
#
# 机器上还留着 26.5 的 SDK —— 它的 SwiftUI 仍是属性包装器，能编过。所以有 26.5
# 就显式用它，没有才回退默认 SDK（装了 Xcode 的机器走后者即可）。
#
# 链接那条不能省：`--sdk` 只管编译阶段，SwiftPM 在链接时会把「部署目标」当成
# SDK 版本写进 LC_BUILD_VERSION（实测写成 14.0）。macOS 26+ 按这个值决定控件
# 用哪套设计，写错会让整个面板退回旧版外观（背景、分段控件颜色全变）。
SDK_DIR="/Library/Developer/CommandLineTools/SDKs"
SDK_26_5="$SDK_DIR/MacOSX26.5.sdk"
MIN_MACOS="14.0"   # 与 Package.swift 的 platforms 保持一致

SDK_ARGS=()
if [[ -d "$SDK_26_5" ]]; then
    SDK_ARGS=(--sdk "$SDK_26_5"
              -Xlinker -platform_version -Xlinker macos
              -Xlinker "$MIN_MACOS" -Xlinker 26.5)
fi

# ---------------------------------------------------------------- 编译

echo "==> 编译 (release)"
# 空数组在 bash 3.2 下直接展开会踩 set -u，分成两条写
if [[ ${#SDK_ARGS[@]} -gt 0 ]]; then
    swift build -c release "${SDK_ARGS[@]}"
else
    swift build -c release
fi

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

ICON_KEY=""
if build_icns; then
    cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "    已嵌入图标"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.liangxu-one.tokenscope</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
${ICON_KEY}
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>TokenScope</string>
</dict>
</plist>
PLIST

# 本地签名，否则未签名二进制会被 macOS 直接终止
echo "==> 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    （签名跳过）"

# 刷新图标缓存，避免 Finder 显示旧图标
touch "$APP"

echo "==> 完成: $(pwd)/$APP"

if [[ "${1:-}" == "run" ]]; then
    echo "==> 重启应用"
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 0.5
    open "$APP"
    echo "    已启动，图标在菜单栏右上角（Clawd 小螃蟹，请求在途时会爬）"
fi
