#!/usr/bin/env python3
"""
统计报表：读取 ai_stats-YYYY-MM-DD.jsonl，按渠道/模型汇总。

指标口径：

    缓存命中率 = Σ cached_tokens / Σ total_input_tokens
                = Σ cached / Σ (new_input + cached + cache_creation)

务必先分别求和、再相除（pooled ratio）。
绝对不能对每条请求各算一次命中率再取平均——那样小请求和大请求权重相同，结果无意义。

分母**包含** cache_creation_tokens，回答的是
「全部输入 token 里有多少是靠缓存复用的」。
此口径与 new-api 不同（它的分母不含缓存写入），详见 http_proxy.py 文件头。

用法：
    python3 stats_report.py              # 今天
    python3 stats_report.py 2026-07-29   # 指定日期
    python3 stats_report.py --all        # 全部历史
"""

import glob
import json
import os
import sys
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_records(target_date=None):
    """加载统计记录。target_date 为 None 时读取全部。"""
    if target_date:
        paths = [os.path.join(SCRIPT_DIR, f"ai_stats-{target_date}.jsonl")]
    else:
        paths = sorted(glob.glob(os.path.join(SCRIPT_DIR, "ai_stats-*.jsonl")))

    records = []
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except ValueError:
                    continue
    return records


class Bucket:
    """一个聚合单元：累加原始 token 总量，最后才求比率"""

    __slots__ = (
        "requests", "failed", "new_input", "cached", "cache_creation",
        "output", "durations", "ttfts",
    )

    def __init__(self):
        self.requests = 0
        self.failed = 0
        self.new_input = 0
        self.cached = 0
        self.cache_creation = 0
        self.output = 0
        self.durations = []
        self.ttfts = []

    def add(self, rec):
        self.requests += 1
        if rec.get("status_code") != 200 or rec.get("error"):
            self.failed += 1

        t = rec.get("tokens") or {}
        self.new_input += t.get("new_input_tokens") or 0
        self.cached += t.get("cached_tokens") or 0
        self.cache_creation += t.get("cache_creation_tokens") or 0
        self.output += t.get("output_tokens") or 0

        if rec.get("duration_ms"):
            self.durations.append(rec["duration_ms"])
        if rec.get("ttft_ms"):
            self.ttfts.append(rec["ttft_ms"])

    # ---- 以下为派生指标，全部基于已汇总的总量计算 ----

    @property
    def total_input(self):
        """真实总输入：新增 + 缓存读 + 缓存写"""
        return self.new_input + self.cached + self.cache_creation

    @property
    def hit_rate_denominator(self):
        """命中率分母 = 真实总输入（含缓存写入，不含输出）"""
        return self.total_input

    @property
    def cache_hit_rate(self):
        """Σcached / Σtotal_input，先汇总再相除"""
        denominator = self.hit_rate_denominator
        return self.cached * 100.0 / denominator if denominator else 0.0

    @property
    def total_tokens(self):
        return self.total_input + self.output

    @property
    def billable_tokens(self):
        """
        计费口径的 token 量（缓存读取便宜、写入偏贵）。
        倍率取 new-api 的默认值：读 0.1，写 1.25（setting/ratio_setting/cache_ratio.go）。
        仅用于横向对比成本量级，不等于真实账单。
        """
        return self.new_input + self.cached * 0.1 + self.cache_creation * 1.25 + self.output

    def percentile(self, values, p):
        if not values:
            return 0
        ordered = sorted(values)
        idx = min(int(len(ordered) * p / 100), len(ordered) - 1)
        return ordered[idx]


def fmt(n):
    """大数字紧凑显示"""
    if n >= 100_000_000:
        return f"{n / 100_000_000:.2f}亿"
    if n >= 10_000:
        return f"{n / 10_000:.1f}万"
    return f"{int(n):,}"


def aggregate(records, key_func):
    buckets = {}
    for rec in records:
        key = key_func(rec)
        buckets.setdefault(key, Bucket()).add(rec)
    return buckets


def print_table(title, buckets, key_label, sort_key=None):
    if not buckets:
        return

    print(f"\n{title}")
    print("─" * 118)
    header = (
        f"{key_label:<22}{'请求':>6}{'失败':>6}{'新增输入':>10}{'缓存读':>10}"
        f"{'缓存写':>10}{'输出':>9}{'命中率':>8}{'总输入':>10}"
        f"{'首字P50':>9}{'耗时P50':>9}{'耗时P95':>9}"
    )
    print(header)
    print("─" * 118)

    sort_key = sort_key or (lambda kv: -kv[1].total_tokens)
    for key, b in sorted(buckets.items(), key=sort_key):
        name = str(key)
        if len(name) > 21:
            name = name[:18] + "..."
        print(
            f"{name:<22}{b.requests:>6}{b.failed:>6}"
            f"{fmt(b.new_input):>10}{fmt(b.cached):>10}{fmt(b.cache_creation):>10}"
            f"{fmt(b.output):>9}{b.cache_hit_rate:>7.1f}%{fmt(b.total_input):>10}"
            f"{b.percentile(b.ttfts, 50):>9}{b.percentile(b.durations, 50):>9}"
            f"{b.percentile(b.durations, 95):>9}"
        )


def balance_line():
    """
    查一行渠道剩余额度。失败返回 None —— 报表的主体是本地 jsonl，
    额度查不到不该让整份报表出不来。
    """
    try:
        from balance import collect, one_line
        return one_line(collect()) or None
    except Exception as e:
        return f"（查询失败：{type(e).__name__}）"


def main():
    args = [a for a in sys.argv[1:] if a]

    # 额度查询要联网，**默认不做** —— 这个工具原本纯读本地文件，
    # 离线可用、瞬间出结果，不该因为多一行额度就变成每次都等网络。
    want_balance = "--balance" in args
    args = [a for a in args if a != "--balance"]

    if "--all" in args:
        target = None
        scope = "全部历史"
    elif args:
        target = args[0]
        scope = target
    else:
        target = datetime.now().strftime("%Y-%m-%d")
        scope = f"{target}（今日）"

    records = load_records(target)
    if not records:
        print(f"没有找到 {scope} 的统计数据")
        return

    total = Bucket()
    for rec in records:
        total.add(rec)

    print("=" * 118)
    print(f"AI 代理使用统计  |  范围: {scope}  |  共 {len(records)} 条请求")
    if want_balance:
        line = balance_line()
        if line:
            print(f"剩余额度  {line}")
    print("=" * 118)

    print(f"""
总览
  请求数        {total.requests}  （失败 {total.failed}）
  新增输入      {fmt(total.new_input):>12}
  缓存读取      {fmt(total.cached):>12}
  缓存写入      {fmt(total.cache_creation):>12}
  输出          {fmt(total.output):>12}
  ─────────────────────────
  真实总输入    {fmt(total.total_input):>12}   （新增 + 缓存读 + 缓存写）
  总 token      {fmt(total.total_tokens):>12}
  计费等效      {fmt(total.billable_tokens):>12}   （缓存读×0.1 + 缓存写×1.25）

  缓存命中率    {total.cache_hit_rate:>11.2f}%   = Σ{fmt(total.cached)} / Σ{fmt(total.hit_rate_denominator)}
                             （先汇总再相除，分母为真实总输入）""")

    print_table("按渠道", aggregate(records, lambda r: r.get("provider") or "?"), "渠道")
    print_table("按模型", aggregate(records, lambda r: r.get("model") or "?"), "模型")
    print_table(
        "按渠道 + 协议格式",
        aggregate(records, lambda r: f"{r.get('provider')}/{r.get('api_format')}"),
        "渠道/格式",
    )

    errors = [r for r in records if r.get("error")]
    if errors:
        print(f"\n失败请求（{len(errors)} 条）")
        print("─" * 118)
        for r in errors[-10:]:
            msg = str(r.get("error", ""))[:70].replace("\n", " ")
            print(f"  {r['timestamp']}  {r.get('provider'):<10}{r.get('model'):<24}"
                  f"{r.get('status_code')}  {msg}")

    print()


if __name__ == "__main__":
    main()
