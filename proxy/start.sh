#!/bin/bash
# 启动 TokenScope 代理
#
# 用法：
#   ./start.sh              前台运行，日志打到终端
#   ./start.sh -d           后台运行，日志写入 http_proxy.log
#   ./start.sh -c           前台运行 + 开启抓包（排查 token 对不上时用）
#   ./start.sh stop         停止代理
#   ./start.sh log          跟踪日志
set -euo pipefail

cd "$(dirname "$0")"

PORT=12345
LOG="http_proxy.log"

stop_proxy() {
    local pids
    pids=$(lsof -ti:$PORT 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 1
        # 还没退就强杀
        pids=$(lsof -ti:$PORT 2>/dev/null || true)
        [[ -n "$pids" ]] && echo "$pids" | xargs kill -9 2>/dev/null || true
        echo "已停止旧进程"
    fi
}

case "${1:-}" in
    stop)
        stop_proxy
        exit 0
        ;;
    log)
        tail -f "$LOG"
        exit 0
        ;;
esac

stop_proxy

# -u 关闭输出缓冲，否则日志会积压在缓冲区里看不到
CMD=(python3 -u http_proxy.py)

# 注意：日志文件由 Python 自己写入并轮转（RotatingFileHandler），
# 这里不要再用 >> 重定向到同一个文件，否则两个写入方会互相干扰。
# 后台运行时把终端输出丢弃即可。
case "${1:-}" in
    -d)
        nohup "${CMD[@]}" > /dev/null 2>&1 &
        sleep 1.5
        if lsof -ti:$PORT > /dev/null 2>&1; then
            echo "✅ 代理已后台启动 (pid $(lsof -ti:$PORT))"
            echo "   日志: $(pwd)/$LOG"
            echo "   跟踪: ./start.sh log"
        else
            echo "❌ 启动失败，查看 $LOG"
            tail -20 "$LOG" 2>/dev/null
            exit 1
        fi
        ;;
    -c)
        echo "抓包模式：报文写入 captures/（含明文对话，注意隐私）"
        AI_PROXY_CAPTURE=1 exec "${CMD[@]}"
        ;;
    *)
        exec "${CMD[@]}"
        ;;
esac
