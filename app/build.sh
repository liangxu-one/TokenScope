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

# ---------------------------------------------------------------- 编译

echo "==> 编译 (release)"
swift build -c release

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
    echo "    已启动，图标在菜单栏右上角（⚡）"
fi
