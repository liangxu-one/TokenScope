#!/usr/bin/env python3
"""zcode_reader.py —— 从 ZCode 的用量库旁路拉取模型调用明细，落进 ai_stats。

角色分工（2026-09-10 重写版，架构性修双计）：

- ZCode 发起的请求（带 ``x-session-id``）由本读取器**唯一**记账：db.sqlite 是
  ZCode 自己的权威账本，和请求走哪条路（网关/直连/baseURL 被写回）无关；
- http_proxy.py 对这类请求只透传、不落 ai_stats（同一天改的，见它的
  record() 里 x-session-id 分支），其余客户端走 12345 的流量照旧网关记账。

两个来源**按构造互斥**——2026-08-27 那版双计（GATEWAY+READER 同一轮各记一条）
的根因就是两条路径没有互斥，这次不是修 bug，是改架构。

数据源：``~/.zcode/cli/db/db.sqlite`` 的 ``model_usage``（每次模型调用一行）。
⛔ 永远不要用 ``turn_usage``：它是轮级聚合，computed_total_tokens 与分列之和对
不上（实测差近一半）。

语义（全部实测钉死，改前先回去核对 2026-09/2026-09-06 的记忆笔记）：

- ``input_tokens`` 是 OpenAI 语义，**已含缓存**：
  ``new_input = max(input − cache_read − cache_creation, 0)``，照
  http_proxy.normalize_responses_usage 的先例。实测 7187 行里减法穿底的 0 条。
- ``output_tokens`` **已含 reasoning**（reasoning > output 的行实测 0 条），
  不另加，与 TokenScope「输出含 reasoning」约定天然一致。
- ``started_at`` 等时间列单位**毫秒**；CPA usage_log 才是纳秒，别混。
- 时间过滤禁用 SQLite 的 ``'utc'`` 修饰符（本机沙箱下窗口错位，2026-09-02 踩过）。
- 只导 ``status='completed'``；``running`` 挂起下轮重试（超过 STALE_H 仍 running
  的视为死行丢弃，否则水位被它堵死）；``error/cancelled`` 丢弃——计费侧不认账
  （4 条断开记录在 CPA usage_log 全部零记录）。

幂等：状态文件记 rowid 水位；行级再按 ``req_id``（= ``zcode-<model_usage.id>``）
在目标天文件里查重——状态文件丢了也不会重复记账。req_id 是 ai_stats 行里的
多余键，Swift 端 JSONDecoder 对未知键忽略，AiStat 解码不受影响。

首跑（无状态文件）**只立水位、不追历史**：历史已由网关记过（09-07~09-09 的
glm/gpt 行），追了就是双计。想重导某段历史是高级操作，手工删水位前先想清楚。

远程：``--remote 2222`` 走 ssh 隧道读远端那份库（五台开发机 NFS 共享一库），
状态文件按端口分开放，两边水位互不干扰。

调度：launchd 每 5 分钟一次（见仓库外 ~/Library/LaunchAgents 的 plist）；也可
手动 ``python3 zcode_reader.py`` 随时跑，幂等。

    python3 zcode_reader.py            # 本地库
    python3 zcode_reader.py --remote 2222
    python3 zcode_reader.py --check    # 对账：db vs ai_stats（按天分解）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_DB = os.path.expanduser("~/.zcode/cli/db/db.sqlite")
STATE_FILE = os.path.join(SCRIPT_DIR, ".zcode_sync_state.json")
# ai_stats 落盘目录。与网关同目录才能被 app 读到；测试里 monkeypatch 它隔离。
STATS_DIR = SCRIPT_DIR
STATS_PREFIX = "ai_stats-"
STATS_SUFFIX = ".jsonl"
# running 行超过这个时长仍没完成，视为进程死亡留下的死行，丢弃放行水位。
STALE_H = 24
# 与网关 purge_old_stats 的保留期一致：更老的行不再写文件（文件早被清了）。
RETENTION_DAYS = 3

# 渠道视图分组名，与网关落盘的 provider 取值对齐（app 按它分组）。
PROVIDER_RULES = (
    ("glm", "glm"),
    ("gpt", "gpt"),
    ("minimax", "minimax"),
)


def provider_for_model(model_id: str) -> str:
    """模型名 → 渠道视图分组名。db 里的 provider_id 是 UUID，没法用。"""
    lower = (model_id or "").lower()
    for prefix, provider in PROVIDER_RULES:
        if lower.startswith(prefix + "-") or lower == prefix:
            return provider
    return lower.split("-", 1)[0] if lower else "unknown"


def new_input_of(input_tokens: int, cache_read: int, cache_creation: int) -> int:
    """input 是 OpenAI 语义（含缓存），剥出纯新增部分，穿底兜 0。"""
    return max(input_tokens - cache_read - cache_creation, 0)


def fmt_ts(ms: int) -> str:
    """毫秒 epoch → 本地时间字符串。格式必须与网关一致（app 按它分桶）。"""
    return dt.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M:%S")


def stats_file_for(ts_ms: int) -> str:
    day = dt.datetime.fromtimestamp(ts_ms / 1000).strftime("%Y-%m-%d")
    return os.path.join(STATS_DIR, f"{STATS_PREFIX}{day}{STATS_SUFFIX}")


def build_stat(row: sqlite3.Row) -> dict:
    """model_usage 行 → ai_stats 记录。字段形状对齐 AiStat（DailyStats.swift）：
    必填 timestamp/model/tokens{4 项}；duration_ms/ttft_ms 有则给；
    api_format/path/stream/status_code 账本里没有对应事实，宁可缺省不编。"""
    tokens = {
        "new_input_tokens": new_input_of(
            row["input_tokens"],
            row["cache_read_input_tokens"],
            row["cache_creation_input_tokens"],
        ),
        "cached_tokens": row["cache_read_input_tokens"],
        "cache_creation_tokens": row["cache_creation_input_tokens"],
        "output_tokens": row["output_tokens"],
    }
    total_input = (
        tokens["new_input_tokens"]
        + tokens["cached_tokens"]
        + tokens["cache_creation_tokens"]
    )
    tokens["total_input_tokens"] = total_input
    tokens["total_tokens"] = total_input + tokens["output_tokens"]
    # 命中率分母 = 真实总输入，与网关 record() 同一口径。
    tokens["hit_rate_denominator"] = total_input
    stat = {
        "timestamp": fmt_ts(row["started_at"]),
        "provider": provider_for_model(row["model_id"]),
        "model": row["model_id"].lower(),
        "req_id": f"zcode-{row['id']}",
        "duration_ms": row["duration_ms"],
        "ttft_ms": row["time_to_first_token_ms"],
        "tokens": tokens,
    }
    return stat


def day_file_has(path: str, req_id: str) -> bool:
    """目标天文件里是否已有这条 req_id（状态文件丢失后的第二道防重）。"""
    if not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as f:
        return any(req_id in line for line in f)


def open_db(db_path: str) -> sqlite3.Connection:
    """只读打开。WAL 库的只读连接偶发打不开时，退回拷贝三件套再读。"""
    uri = f"file:{db_path}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("SELECT count(*) FROM model_usage").fetchone()
        return conn
    except sqlite3.OperationalError:
        tmp = os.path.join(tempfile.mkdtemp(prefix="zcode_reader_"), "db.sqlite")
        for ext in ("", "-wal", "-shm"):
            src = db_path + ext
            if os.path.exists(src):
                shutil.copy2(src, tmp + ext)
        conn = sqlite3.connect(tmp, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn


def fetch_remote_db(port: int) -> str:
    """ssh 隧道端口上的远端库 → 临时文件路径（五台一库，读一份即全部）。"""
    tmp = os.path.join(tempfile.mkdtemp(prefix="zcode_reader_"), "remote.sqlite")
    cmd = ["ssh", "-o", "ConnectTimeout=8", "-p", str(port), "localhost",
           "cat", LOCAL_DB]
    with open(tmp, "wb") as f:
        subprocess.run(cmd, stdout=f, check=True)
    return tmp


def load_state(path: str) -> dict | None:
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return None


def save_state(path: str, state: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def sync(db_path: str, state_path: str) -> int:
    state = load_state(state_path)
    stale_cutoff = int((dt.datetime.now() - dt.timedelta(hours=STALE_H))
                       .timestamp() * 1000)

    conn = open_db(db_path)
    try:
        if state is None:
            # 首跑只立水位。历史由网关记过账，追了就是双计（2026-08-27 实锤）。
            watermark = conn.execute(
                "SELECT COALESCE(MAX(rowid), 0) FROM model_usage").fetchone()[0]
            save_state(state_path, {"max_rowid": watermark})
            print(f"[INIT] 水位立在 rowid={watermark}，不追历史（网关已记过的"
                  f"账再导就是双计）。此后每次运行导增量。")
            return 0

        watermark = int(state.get("max_rowid", 0))
        rows = conn.execute(
            "SELECT rowid, * FROM model_usage WHERE rowid > ? ORDER BY rowid",
            (watermark,),
        ).fetchall()
    finally:
        conn.close()

    imported = dropped = 0
    still_running = []
    new_watermark = watermark
    by_file = {}
    for row in rows:
        rowid, status, started = row["rowid"], row["status"], row["started_at"]
        if status == "running":
            if started < stale_cutoff:
                dropped += 1          # 死行：进程死了永远停在 running
                new_watermark = rowid
            else:
                still_running.append(rowid)   # 挂起，下轮重试
            continue
        new_watermark = rowid         # error/cancelled/completed 都放行水位
        if status != "completed":
            dropped += 1              # 计费侧不认账，同网关 if error 清零的取舍
            continue
        if started / 1000 < dt.datetime.now().timestamp() - RETENTION_DAYS * 86400:
            dropped += 1              # 太老：天文件早被清了，写回去没有意义
            continue
        stat = build_stat(row)
        path = stats_file_for(row["started_at"])
        if day_file_has(path, stat["req_id"]):
            continue                  # 状态文件丢过一次的补账场景，防重
        by_file.setdefault(path, []).append(stat)

    for path, stats in by_file.items():
        with open(path, "a", encoding="utf-8") as f:
            for stat in stats:
                f.write(json.dumps(stat, ensure_ascii=False) + "\n")
        imported += len(stats)

    # ⚠️ 水位不能越过任何仍 在途 的行：它完成后的 UPDATE 不产生新 rowid，
    # 水位一旦越过就永远查不到它了。封顶到最早的在途行之前，已完成的行靠
    # day_file_has() 的 req_id 查重防重复导出。
    if still_running:
        new_watermark = min(new_watermark, min(still_running) - 1)
    state["max_rowid"] = max(watermark, new_watermark)
    if still_running:
        state["pending"] = still_running
    else:
        state.pop("pending", None)
    save_state(state_path, state)

    print(f"[SYNC] 新增 {imported} / 丢弃 {dropped} / 在途 {len(still_running)}"
          f" | 水位 rowid={state['max_rowid']}")
    return 0


def backfill_day(day: str) -> int:
    """补导指定某天 db 里的 completed 行。只用于切换过渡日（如 2026-09-10：
    网关整天被绕行、reader 又还没上线，那段账两边都没记）。

    守卫：目标天文件里只要还有**不带 req_id 的行**（= 网关记的账），就拒绝——
    那天网关在工作，回填就是双计（09-07~09-09 就是这种，别碰）。导过的行靠
    req_id 查重天然幂等；水位不动（只往前走，不回头）。
    """
    path = os.path.join(STATS_DIR, f"{STATS_PREFIX}{day}{STATS_SUFFIX}")
    gateway_rows = 0
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            try:
                if "req_id" not in json.loads(line):
                    gateway_rows += 1
            except json.JSONDecodeError:
                gateway_rows += 1     # 坏行按网关行从严处理
    if gateway_rows:
        print(f"⛔ {day} 的文件里有 {gateway_rows} 行网关记录（不带 req_id），"
              f"回填会双计。只有网关当天没记过账（文件没有/全是 req_id 行）才许回填。")
        return 1

    conn = open_db(LOCAL_DB)
    try:
        rows = conn.execute(
            "SELECT rowid, * FROM model_usage WHERE status='completed' "
            "AND strftime('%Y-%m-%d', started_at/1000, 'unixepoch', "
            "'localtime') = ? ORDER BY rowid", (day,)).fetchall()
    finally:
        conn.close()

    imported = skipped = 0
    with open(path, "a", encoding="utf-8") as f:
        for row in rows:
            stat = build_stat(row)
            if day_file_has(path, stat["req_id"]):
                skipped += 1
                continue
            f.write(json.dumps(stat, ensure_ascii=False) + "\n")
            imported += 1
    print(f"[BACKFILL] {day}: 新增 {imported} / 已存在跳过 {skipped}"
          f"（水位不动）")
    return 0


def check() -> int:
    """对账：db 里近 N 天 completed 行 vs ai_stats 里 req_id 行（reader 记的）。
    差额 = 网关记的那部分（x-session-id 拦截上线前经 12345 的流量）或直连流量
    在 reader 水位未覆盖的时段，人工判读，不自动下结论。"""
    now = dt.datetime.now()
    days = [ (now - dt.timedelta(days=i)).strftime("%Y-%m-%d")
             for i in range(RETENTION_DAYS) ]
    conn = open_db(LOCAL_DB)
    try:
        for day in days:
            rows = conn.execute(
                "SELECT COUNT(*) FROM model_usage WHERE status='completed' "
                "AND strftime('%Y-%m-%d', started_at/1000, 'unixepoch', "
                "'localtime') = ?", (day,)).fetchone()[0]
            path = os.path.join(STATS_DIR, f"{STATS_PREFIX}{day}{STATS_SUFFIX}")
            zcode = gateway = 0
            if os.path.exists(path):
                for line in open(path, encoding="utf-8"):
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if "req_id" in rec:
                        zcode += 1
                    else:
                        gateway += 1
            flag = "" if rows == zcode + gateway else "  ⚠️ 对不上"
            print(f"{day}  db={rows}  ai_stats={zcode + gateway}"
                  f"  (reader {zcode} + gateway {gateway}){flag}")
    finally:
        conn.close()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--remote", type=int, metavar="PORT",
                    help="走 ssh 隧道读远端库（如 --remote 2222）")
    ap.add_argument("--check", action="store_true", help="对账模式，不导入")
    ap.add_argument("--backfill-day", metavar="YYYY-MM-DD",
                    help="补导某天（仅限网关当天没记过账的过渡日，有守卫）")
    args = ap.parse_args()

    if args.check:
        return check()

    if args.backfill_day:
        return backfill_day(args.backfill_day)

    if args.remote:
        db_path = fetch_remote_db(args.remote)
        state_path = STATE_FILE.replace(".json", f"-remote{args.remote}.json")
    else:
        db_path = LOCAL_DB
        state_path = STATE_FILE

    if not os.path.exists(db_path):
        print(f"⛔ 找不到用量库: {db_path}", file=sys.stderr)
        return 1
    return sync(db_path, state_path)


if __name__ == "__main__":
    sys.exit(main())
