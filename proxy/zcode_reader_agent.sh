#!/bin/bash
# zcode_reader_agent.sh —— ZCode 用量旁路定时任务的安装/卸载/状态。
#
# 这个脚本让 zcode_reader.py 成为项目自带的能力：clone 后 ./start.sh -d 一次，
# launchd 定时任务就装好了（每 5 分钟从 ZCode 用量库拉一次 token 统计）。
#
# 用法：
#   bash zcode_reader_agent.sh ensure    # 没装就装，装过就校验（幂等，start.sh 自动调）
#   bash zcode_reader_agent.sh install   # 强制（重）装
#   bash zcode_reader_agent.sh remove    # 停掉并删 plist
#   bash zcode_reader_agent.sh status    # 装没装、上次运行结果
#   bash zcode_reader_agent.sh run       # 手动立刻跑一轮（等价于直接跑 zcode_reader.py）
#
# ⚠️ 前提守卫：本功能只对「这台机器上用 ZCode」的人有意义。检测不到
# ~/.zcode/cli/db/db.sqlite 就拒绝安装（start.sh 会静默跳过）——
# 别人不用 ZCode 时项目照常工作，只是没有这块统计。
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.liangxu.zcode-reader"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/zcode-reader.log"
DOMAIN="gui/$(id -u)"
DB="$HOME/.zcode/cli/db/db.sqlite"
PYTHON="$(command -v python3)"
READER="$(pwd)/zcode_reader.py"

loaded() {
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

write_plist() {
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON}</string>
        <string>${READER}</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
EOF
}

guard() {
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "非 macOS，launchd 定时任务不可用，跳过（其余功能不受影响）"
        return 1
    fi
    if [[ ! -f "$DB" ]]; then
        echo "未检测到 ZCode 用量库（${DB}），跳过 reader 定时任务"
        return 1
    fi
    if [[ ! -f "$READER" ]]; then
        echo "找不到 ${READER}，仓库不完整？" >&2
        return 1
    fi
    return 0
}

cmd="${1:-ensure}"
case "$cmd" in
    ensure)
        # 已加载就不动它（避免重置用户的运行节奏）；没加载且守卫通过才装。
        if loaded; then
            exit 0
        fi
        if guard; then
            mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
            write_plist
            launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
                || launchctl load "$PLIST" 2>/dev/null || true
            if loaded; then
                # ⚠️ bash 3.2 坑：$VAR 后面贴全角字符会把全角字节当变量名，
                # 必须 ${VAR}（ —— 本仓库跑批脚本里同样注明过这条。
                echo "✅ zcode_reader 定时任务已安装（每 5 分钟一次，日志: ${LOG_FILE}）"
            else
                echo "⚠️ plist 已写入但未加载，手动查: launchctl print ${DOMAIN}/${LABEL}"
                exit 1
            fi
        fi
        ;;
    install)
        guard
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
        write_plist
        launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
            || launchctl load "$PLIST"
        echo "✅ 已重装（每 5 分钟一次，日志: ${LOG_FILE}）"
        ;;
    remove)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || \
            launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "已移除 zcode_reader 定时任务（统计文件和水位保留）"
        ;;
    status)
        if loaded; then
            echo "已加载: ${DOMAIN}/${LABEL}"
            if [[ -f "$LOG_FILE" ]]; then
                echo "最近一次: $(tail -1 "$LOG_FILE")"
            fi
        elif [[ -f "$PLIST" ]]; then
            echo "plist 存在但未加载: $PLIST"
        else
            echo "未安装"
        fi
        exit 0
        ;;
    run)
        exec "$PYTHON" "$READER" "$@"
        ;;
    *)
        echo "用法: $0 {ensure|install|remove|status|run}"
        exit 1
        ;;
esac
