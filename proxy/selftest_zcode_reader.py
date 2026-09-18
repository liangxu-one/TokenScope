#!/usr/bin/env python3
"""zcode_reader 的换算与防重回归自测。纯 stdlib assert，不引依赖。

    python3 selftest_zcode_reader.py

⚠️ 断言里的期望值不要"顺手改成实际输出"。每条都标注了依据来源：
改动前先回去核对那个来源（db 实测 / AiStat 结构 / 网关同口径代码）。
"""

import json
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import zcode_reader as zr  # noqa: E402

FAILURES = []


def check(name, fn):
    try:
        fn()
        print(f"  ✓ {name}")
    except AssertionError as e:
        FAILURES.append(name)
        print(f"  ✗ {name}: {e}")


# ---------------------------------------------------------------- 换算公式
def test_new_input():
    # 依据 2026-09-10 实测（7187 行）：input 是 OpenAI 语义已含缓存，减法不穿底
    assert zr.new_input_of(100, 60, 10) == 30
    assert zr.new_input_of(142061, 141056, 0) == 1005   # 今日真实 glm 行
    # 理论穿底仍要兜 0（负数进统计就是一眼假）
    assert zr.new_input_of(10, 60, 10) == 0
    assert zr.new_input_of(0, 0, 0) == 0


def test_reasoning_not_added():
    # 依据 2026-09-10 实测：reasoning > output 的行 0 条 → output 已含 reasoning。
    # build_stat 必须原样用 output_tokens，任何"加回 reasoning"的改动都会翻倍。
    row = make_row(output_tokens=130, reasoning_tokens=25)
    stat = zr.build_stat(row)
    assert stat["tokens"]["output_tokens"] == 130


# ---------------------------------------------------------------- 行 → 记录
def make_row(**kw):
    cols = dict(
        id="usage_x_1", model_id="glm-5.3-flash", status="completed",
        started_at=1789000000000, duration_ms=12345,
        time_to_first_token_ms=678,
        session_id="sess_selftest",
        input_tokens=1000, output_tokens=50, reasoning_tokens=0,
        cache_read_input_tokens=800, cache_creation_input_tokens=0,
    )
    cols.update(kw)
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE TABLE t ("
                 + ",".join(f"{k} INTEGER" if k != "id" and k != "model_id"
                            and k != "status" and k != "session_id"
                            else f"{k} TEXT"
                            for k in cols) + ")")
    conn.execute(f"INSERT INTO t VALUES ({','.join('?' * len(cols))})",
                 tuple(cols.values()))
    return conn.execute("SELECT rowid, * FROM t").fetchone()


def test_stat_shape():
    # 依据 AiStat（DailyStats.swift）：必填 timestamp/model/tokens{4 项}；
    # tokens 三件汇总键与网关 record() 同口径；req_id 是防重标记（多余键）。
    stat = zr.build_stat(make_row())
    assert stat["timestamp"] == zr.fmt_ts(1789000000000)
    assert stat["model"] == "glm-5.3-flash"
    assert stat["provider"] == "glm"
    assert stat["req_id"] == "zcode-usage_x_1"
    t = stat["tokens"]
    assert t["new_input_tokens"] == 200 and t["cached_tokens"] == 800
    assert t["cache_creation_tokens"] == 0 and t["output_tokens"] == 50
    assert t["total_input_tokens"] == 1000 and t["total_tokens"] == 1050
    assert t["hit_rate_denominator"] == 1000   # 与网关同口径：真实总输入
    assert stat["duration_ms"] == 12345 and stat["ttft_ms"] == 678
    # Swift JSONDecoder 对未知键忽略——req_id 不得破坏解码的关键字段
    assert set(t) >= {"new_input_tokens", "cached_tokens",
                      "cache_creation_tokens", "output_tokens"}


def test_timestamp_format():
    # 依据：app 按该字符串分桶，格式必须与网关逐字节一致（%F %T 本地时间）
    assert len(zr.fmt_ts(1789000000000)) == 19
    assert zr.fmt_ts(1789000000000)[10] == " "


def test_provider_mapping():
    # 渠道分组名与网关落盘取值对齐（app 按它分组，见 09-07~09-09 ai_stats）
    assert zr.provider_for_model("glm-5.3-flash") == "glm"
    assert zr.provider_for_model("GLM-5.3") == "glm"      # 大小写不敏感
    assert zr.provider_for_model("gpt-5.6-sol") == "gpt"
    assert zr.provider_for_model("minimax-m3") == "minimax"
    assert zr.provider_for_model("claude-x") == "claude"  # 兜底：前缀


# ---------------------------------------------------------------- 防重与文件
def test_day_file_has():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "ai_stats-2026-09-10.jsonl")
        assert not zr.day_file_has(path, "zcode-a")
        with open(path, "w") as f:
            f.write(json.dumps({"req_id": "zcode-a"}) + "\n")
        assert zr.day_file_has(path, "zcode-a")
        assert not zr.day_file_has(path, "zcode-b")
        assert not zr.day_file_has(os.path.join(d, "nope.jsonl"), "zcode-a")


def test_state_watermark_with_pending():
    # 依据 2026-09-10 修复：running 行不产生新 rowid，水位越过它=丢这条。
    # 场景：rowid 1（u100）在途、rowid 2（u101）已完成 → 导出 u101，
    # 但水位必须停在 0（不能越过在途的 rowid 1）。
    with tempfile.TemporaryDirectory() as d:
        zr.STATS_DIR = d
        try:
            db = os.path.join(d, "db.sqlite")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE model_usage (id TEXT PRIMARY KEY,"
                         " status TEXT, started_at INTEGER, duration_ms INTEGER,"
                         " time_to_first_token_ms INTEGER, model_id TEXT,"
                         " session_id TEXT,"
                         " input_tokens INTEGER, output_tokens INTEGER,"
                         " reasoning_tokens INTEGER,"
                         " cache_read_input_tokens INTEGER,"
                         " cache_creation_input_tokens INTEGER)")
            now = int(__import__("time").time() * 1000)
            conn.execute("INSERT INTO model_usage VALUES ('u100','running',?,0,0,"
                         "'glm-5.3-flash','sess_t',0,0,0,0,0)", (now,))
            conn.execute("INSERT INTO model_usage VALUES ('u101','completed',?,5,1,"
                         "'glm-5.3-flash','sess_t',10,2,0,0,0)", (now,))
            conn.commit()
            conn.close()
            state_path = os.path.join(d, "state.json")
            with open(state_path, "w") as f:
                json.dump({"max_rowid": 0}, f)
            zr.sync(db, state_path)
            # 水位被在途行堵在 0；u101 已导出
            assert json.load(open(state_path))["max_rowid"] == 0, \
                f"水位被在途行顶穿: {json.load(open(state_path))}"
            out = os.path.join(d, zr.STATS_PREFIX
                               + zr.fmt_ts(now)[:10] + ".jsonl")
            assert os.path.exists(out), "rowid 2（u101）应该已导出"
            assert "zcode-u101" in open(out).read()
            assert "zcode-u100" not in open(out).read()
            # 再跑一遍：u101 不重复导出（req_id 查重），水位纹丝不动
            zr.sync(db, state_path)
            assert json.load(open(state_path))["max_rowid"] == 0
            assert open(out).read().count("zcode-u101") == 1
            # u100 完成后：导出且水位放行到 2
            conn = sqlite3.connect(db)
            conn.execute("UPDATE model_usage SET status='completed'"
                         " WHERE id='u100'")
            conn.commit()
            conn.close()
            zr.sync(db, state_path)
            assert json.load(open(state_path))["max_rowid"] == 2
            assert open(out).read().count("zcode-u100") == 1
            assert open(out).read().count("zcode-u101") == 1
        finally:
            zr.STATS_DIR = zr.SCRIPT_DIR


def test_first_run_sets_watermark_only():
    # 首跑不追历史——历史已由网关记账，导了就是双计（2026-08-27 实锤）
    with tempfile.TemporaryDirectory() as d:
        db = os.path.join(d, "db.sqlite")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE model_usage (id TEXT PRIMARY KEY, status TEXT,"
                     " started_at INTEGER, duration_ms INTEGER,"
                     " time_to_first_token_ms INTEGER, model_id TEXT,"
                     " input_tokens INTEGER, output_tokens INTEGER,"
                     " reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,"
                     " cache_creation_input_tokens INTEGER)")
        conn.execute("INSERT INTO model_usage VALUES ('u1','completed',0,0,0,"
                     "'glm-5.3-flash',0,0,0,0,0)")
        conn.commit()
        conn.close()
        state_path = os.path.join(d, "state.json")
        zr.sync(db, state_path)
        assert json.load(open(state_path))["max_rowid"] == 1
        # 目录里没有任何 ai_stats 文件产生
        assert not [f for f in os.listdir(d) if f.startswith("ai_stats-")]


def test_error_cancelled_dropped():
    # 依据 2026-09-02 CPA 实测：error/cancelled 计费侧零记录，导了就是幻影用量
    with tempfile.TemporaryDirectory() as d:
        zr.STATS_DIR = d
        try:
            db = os.path.join(d, "db.sqlite")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE model_usage (id TEXT PRIMARY KEY,"
                         " status TEXT, started_at INTEGER, duration_ms INTEGER,"
                         " time_to_first_token_ms INTEGER, model_id TEXT,"
                         " input_tokens INTEGER, output_tokens INTEGER,"
                         " reasoning_tokens INTEGER,"
                         " cache_read_input_tokens INTEGER,"
                         " cache_creation_input_tokens INTEGER)")
            now = int(__import__("time").time() * 1000)
            for i, st in enumerate(("error", "cancelled")):
                conn.execute(
                    "INSERT INTO model_usage (id,status,started_at,duration_ms,"
                    "time_to_first_token_ms,model_id,input_tokens,output_tokens,"
                    "reasoning_tokens,cache_read_input_tokens,"
                    "cache_creation_input_tokens) VALUES (?,?,?,0,0,?,999,99,0,0,0)",
                    (f"u{i}", st, now, "glm-5.3-flash"))
            conn.commit()
            conn.close()
            state_path = os.path.join(d, "state.json")
            with open(state_path, "w") as f:
                json.dump({"max_rowid": 0}, f)
            zr.sync(db, state_path)
            assert json.load(open(state_path))["max_rowid"] == 2
            assert not [f for f in os.listdir(d) if f.startswith("ai_stats-")]
        finally:
            zr.STATS_DIR = zr.SCRIPT_DIR


def test_gateway_direct_guard():
    # 依据 2026-09-18：req_id = gw-<sid> 的行是网关替"会话不在本地库"的流量
    # （远程 ZCode 经隧道、脚本伪造头）直记的账，本地/远端库再导同会话的行
    # 就是双计。守卫只跳该会话的行，其余照导；水位照常放行（分流不是故障）。
    with tempfile.TemporaryDirectory() as d:
        zr.STATS_DIR = d
        try:
            db = os.path.join(d, "db.sqlite")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE model_usage (id TEXT PRIMARY KEY,"
                         " status TEXT, started_at INTEGER, duration_ms INTEGER,"
                         " time_to_first_token_ms INTEGER, model_id TEXT,"
                         " session_id TEXT,"
                         " input_tokens INTEGER, output_tokens INTEGER,"
                         " reasoning_tokens INTEGER,"
                         " cache_read_input_tokens INTEGER,"
                         " cache_creation_input_tokens INTEGER)")
            now = int(__import__("time").time() * 1000)
            conn.execute("INSERT INTO model_usage VALUES ('u200','completed',?,5,1,"
                         "'glm-5.3-flash','sess_remote',10,2,0,0,0)", (now,))
            conn.execute("INSERT INTO model_usage VALUES ('u201','completed',?,5,1,"
                         "'glm-5.3-flash','sess_local',10,2,0,0,0)", (now,))
            conn.commit()
            conn.close()
            out = os.path.join(d, zr.STATS_PREFIX
                               + zr.fmt_ts(now)[:10] + ".jsonl")
            with open(out, "w") as f:
                f.write(json.dumps({"req_id": "gw-sess_remote"}) + "\n")
            state_path = os.path.join(d, "state.json")
            with open(state_path, "w") as f:
                json.dump({"max_rowid": 0}, f)
            zr.sync(db, state_path)
            body = open(out).read()
            assert "zcode-u200" not in body, "gw- 已记账的会话不得再导（双计）"
            assert "zcode-u201" in body, "没有 gw- 行的会话照常导入"
            assert json.load(open(state_path))["max_rowid"] == 2, \
                f"守卫跳过的行也要放行水位: {json.load(open(state_path))}"
        finally:
            zr.STATS_DIR = zr.SCRIPT_DIR


def main():
    print("zcode_reader selftest:")
    check("new_input 减缓存、穿底兜 0", test_new_input)
    check("reasoning 不另加", test_reasoning_not_added)
    check("行 → 记录形状与口径", test_stat_shape)
    check("timestamp 格式", test_timestamp_format)
    check("渠道分组映射", test_provider_mapping)
    check("req_id 查重", test_day_file_has)
    check("水位不在途行上顶穿 + 幂等重放", test_state_watermark_with_pending)
    check("首跑只立水位", test_first_run_sets_watermark_only)
    check("error/cancelled 丢弃", test_error_cancelled_dropped)
    check("网关直记守卫（gw- 会话整段跳过）", test_gateway_direct_guard)
    if FAILURES:
        print(f"\n❌ {len(FAILURES)} 项失败: {FAILURES}")
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
