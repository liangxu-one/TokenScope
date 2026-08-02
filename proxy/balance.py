#!/usr/bin/env python3
"""
查询各渠道的剩余额度。

    python3 balance.py                  # 表格输出
    python3 balance.py --json           # 机器可读，供接界面或 cron
    python3 balance.py --providers      # 列出已内置的提供方
    python3 balance.py --min 5          # 任一货币余额低于 5 则退出码 1（告警用）

--------------------------------------------------------------------------------
两种额度语义，不能混为一谈
--------------------------------------------------------------------------------
各家「剩余额度」根本不是同一种东西，所以归一化成两个 kind：

    currency  货币余额。有金额与币种，随消耗单调减少，只有充值才回升。
              没有「重置时间」这个概念。          例：DeepSeek ¥10.73
    quota     套餐额度。只有已用百分比与时间窗口，到点自动重置，没有面值。
              例：MiniMax 5 小时窗已用 1%、7 天窗已用 23%

⚠️ 别把 quota 折算成金额，也别给 currency 编一个百分比 —— 前者没有面值，
后者没有分母。展示侧必须按 kind 分别渲染。

--------------------------------------------------------------------------------
查哪些渠道
--------------------------------------------------------------------------------
从 ai_stats_domains.json 里已配置的渠道来（routes 与 aggregate.targets 都算），
按**上游域名**匹配内置提供方：

    匹配到 + ai_keys.json 里有 key   → 查询并展示
    匹配到但缺 key                   → 展示一行提示（这是可修的配置问题）
    没匹配到                         → 完全不显示，不打扰

请求**直连上游**，不走本地代理 —— 这不是 LLM 调用，没有统计价值，
走代理只会往 jsonl 里塞无意义的记录。

--------------------------------------------------------------------------------
只内置了 DeepSeek 与 MiniMax
--------------------------------------------------------------------------------
刻意只内置这两家：它们是本仓库能**实测验证过**的。各家余额接口的字段语义差异
极大（见下面两个实现里标注的坑），凭文档照抄而不实测，很容易写出"看起来有数字
但其实错了"的解析 —— 那比没有这个功能更糟。

要加自己的渠道很简单，照下面 `@provider` 的样子写一个函数即可，详见 README。
其他厂商的端点与字段可参考 cc-switch 的实现（它覆盖面广得多）：

    src-tauri/src/services/balance.rs       货币余额：StepFun / SiliconFlow /
                                            OpenRouter / Novita AI 等
    src-tauri/src/services/coding_plan.rs   套餐额度：Kimi / 智谱 / ZenMux 等

注意火山方舟不能照抄：它走控制面 OpenAPI 且强制火山签名 V4（AK/SK 一对，
不是单个 key），凭据模型与这里不兼容。
"""

import argparse
import json
import os
import sys
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime
from urllib.parse import urlsplit

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

# 复用代理的配置加载，避免两处各写一份解析
from http_proxy import load_aggregate, load_keys, read_domains_file  # noqa: E402

TIMEOUT = 15


# ============================================================ 提供方注册表

PROVIDERS = []


def provider(provider_id, *domains):
    """
    注册一个额度提供方。

    domains 是**完整主机名**（不是片段），配置里的主机名等于它、或是它的真子域，
    即认为该渠道属于本提供方。
    被装饰的函数签名为 `query(api_key, base_url) -> dict`，
    返回值用下面 currency() / quota() / failure() 三个构造器生成。

    base_url 传的是该渠道在配置里的上游地址（有多个端点时传第一个）——
    大多数厂商的额度接口是固定域名、用不到它；但有的厂商（如自建网关、
    区域域名不同）需要据此拼接，所以统一传进来。
    """
    def wrap(fn):
        PROVIDERS.append({"id": provider_id, "domains": domains, "query": fn})
        return fn
    return wrap


def host_of(raw):
    """
    从配置里的上游地址取出主机名，取不到返回 None。

    用 `hostname` 而不是 `netloc`：后者会把 userinfo 和端口一并带上，
    而 `https://api.deepseek.com@evil.example/` 的真实主机是 evil.example。

    裸域名（`routes` 里配的就是 `api.deepseek.com` 这种没有 scheme 的形状）
    要先补 `//`，否则 urlsplit 会把整串当成 path、netloc 为空。
    """
    text = str(raw).strip().lower()
    if "://" not in text:
        text = "//" + text
    return urlsplit(text).hostname


def find_provider(base_urls):
    """
    按主机名找提供方。找不到返回 None（调用方应静默跳过）。

    ⚠️ 必须比对**解析出来的主机名**，不能拿域名去 `in` 整个 URL 做子串匹配。
    子串匹配会把下面三种都误判成本家（均已实测）：

        api.deepseek.com.evil.example       后缀冒充
        api.deepseek.com@evil.example       userinfo 冒充，真实主机是后者
        evil.example/?x=api.deepseek.com    塞在 query string 里

    内置两家的额度接口 URL 是写死的，判错只是显示不对；但 @provider 会把
    base_url **交给第三方实现**去拼 URL（上面 provider() 的文档就是这么承诺的），
    判错就等于把那家的 key 发到配置里写的任意主机上。
    """
    hosts = [h for h in (host_of(u) for u in base_urls) if h]
    for entry in PROVIDERS:
        for host in hosts:
            # 等于，或是真子域：cn.api.deepseek.com 算，api.deepseek.com.x 不算
            if any(host == d or host.endswith("." + d) for d in entry["domains"]):
                return entry
    return None


# ============================================================ 结果构造器

def currency(balances, *, available=True):
    """
    货币余额结果。

    balances: [{"currency": "CNY", "total": 10.73}]

    只存**能用的总额**。赠金/充值的拆分刻意不收：
    DeepSeek 会返回 granted_balance 与 topped_up_balance，但二者之和恒等于
    total_balance，多存一份就是等着漂移；而「赠金快到期了」这种真正值得提醒的
    信息接口里并没有给（没有到期时间），拆开也不可行动。
    真要区分的渠道，自己在 @provider 实现里往 balance 里加键即可 —— 展示侧
    忽略不认识的键。
    """
    return {"kind": "currency", "ok": True,
            "is_available": bool(available), "balances": balances}


def quota(windows):
    """
    套餐额度结果。

    windows: [{"label": "5 小时", "used_percent": 1.0,
               "resets_at": "2026-08-02 20:00"},
              {"label": "7 天", "used_percent": 23.0, "resets_at": "..."}]
    按时间窗口从短到长排列。resets_at 可为 None。

    ⚠️ 存的是**已用**百分比，与 cc-switch 的 QuotaTier.utilization 一致。
    多数厂商接口给的是「剩余」，实现里要自己反转成已用（见 parse_minimax）。
    只存一个方向、不同时存两份 —— 两份会漂移。剩余量由展示侧算 100 - used。
    """
    return {"kind": "quota", "ok": True, "windows": windows}


def failure(message, *, transient=False):
    """
    查询失败。

    transient=True  网络不可达 / 超时 → 值得重试，展示侧应保留上次成功值
    transient=False 鉴权失败 / 非 2xx / 响应体非法 → 重试无用，立即透出

    这个区分沿用 cc-switch balance.rs 的错误通道语义。现在 CLI 用不上，
    但接入界面做定时轮询时，它决定「显示红色错误」还是「继续显示上次的值」。
    """
    return {"kind": "error", "ok": False, "error": message, "transient": transient}


# ============================================================ 给实现者的工具

def parse_number(obj, field):
    """
    取数值字段，兼容数字与字符串两种写法。

    ⚠️ 必须兼容字符串：DeepSeek 的 total_balance 返回的是 "10.73" 而不是 10.73。
    直接当数字取会拿到 None、余额显示成 0 —— 这是个静默错误，界面上看不出来。
    实测各家在这点上很随意，新增提供方时一律用这个函数取数。
    """
    value = (obj or {}).get(field)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def millis_to_local(ms):
    """毫秒时间戳 → 本地时间字符串。非法值返回 None 而不是抛异常。"""
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def fetch(url, api_key, *, bearer=True, headers=None):
    """
    GET 一个 JSON 接口，返回 (payload, failure_dict)。成功时 failure_dict 为 None。

    bearer=False 时 Authorization 直接填 api_key 不加 "Bearer " 前缀 ——
    确实有厂商这么要求（智谱就是），所以留了这个开关。
    """
    request_headers = {
        "Authorization": f"Bearer {api_key}" if bearer else api_key,
        "Accept": "application/json",
    }
    request_headers.update(headers or {})

    request = urllib.request.Request(url, headers=request_headers, method="GET")

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            raw = response.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        if e.code in (401, 403):
            return None, failure(f"鉴权失败 (HTTP {e.code})")
        return None, failure(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        return None, failure(f"网络不可达: {e.reason}", transient=True)
    except Exception as e:
        return None, failure(f"{type(e).__name__}: {e}", transient=True)

    try:
        return json.loads(raw), None
    except ValueError as e:
        return None, failure(f"响应不是合法 JSON: {e}")


# ============================================================ 内置实现

@provider("deepseek", "api.deepseek.com")
def query_deepseek(api_key, base_url):
    """
    DeepSeek —— 货币余额型的参考实现。

    GET https://api.deepseek.com/user/balance
    {
      "is_available": true,
      "balance_infos": [{ "currency": "CNY", "total_balance": "10.73",
                          "granted_balance": "0.00", "topped_up_balance": "10.73" }]
    }

    ⚠️ 金额字段是**字符串**，务必用 parse_number 取。
    balance_infos 是数组：多币种账户会返回多条，各自独立，不能相加。

    granted / topped_up 两项**故意不取**（理由见 currency()）：它们之和恒等于
    total_balance，是同一笔钱的两种切法，不是额外信息。
    """
    payload, error = fetch("https://api.deepseek.com/user/balance", api_key)
    return error or parse_deepseek(payload)


def parse_deepseek(payload):
    """
    与网络请求分离，便于不联网单测（见 selftest_usage.py）。
    自己加提供方时建议照这个样子拆，解析逻辑才测得动。
    """
    infos = (payload or {}).get("balance_infos")
    if not isinstance(infos, list) or not infos:
        return failure("响应里没有 balance_infos")

    balances = [{
        "currency": info.get("currency") or "CNY",
        "total": parse_number(info, "total_balance"),
    } for info in infos]

    return currency(balances, available=payload.get("is_available", True))


@provider("minimax", "api.minimaxi.com", "api.minimax.io")
def query_minimax(api_key, base_url):
    """
    MiniMax 编程套餐 —— 套餐额度型的参考实现。注意它没有金额，只有百分比。

    GET https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains
    （国际站是 api.minimax.io，路径相同）

    三个坑，均按 cc-switch coding_plan.rs parse_minimax_tiers 处理，且已实测印证：

      1. model_remains 里同时有 general 和 video 两条。只能取 general ——
         video 是视频模型，百分比恒为 100，混进去会把数字冲淡。
      2. 上游字段是「剩余」百分比（current_*_remaining_percent），
         而本模块统一存**已用**，所以要做 100 - x 反转（与 cc-switch 的
         utilization 一致）。搞错方向不会报错，只会让 1% 显示成 99%。
      3. 第二个窗口必须看 current_weekly_status == 1 才算激活。无该限额的套餐
         该值为 3 且剩余恒 100（即已用 0），照展示出来是假信息。

    标签叫「7 天」而不是「周」：实测 weekly_end_time - weekly_start_time
    恰好 604800000ms（7×24h），是**滚动 7 天窗**，不是自然周。叫「周」会让人
    误以为周一清零。

    另外它有业务级错误码：HTTP 200 也可能是失败，必须单独查 base_resp。
    """
    # 在**解析出的主机名**上判国际站，不在原始 URL 上判 —— 后者会被
    # query string 里的字样带跑（`?ref=minimax.io`）。走到这里 find_provider
    # 已经认过主机名，所以它一定是 api.minimaxi.com 或 api.minimax.io（或其子域）。
    host = host_of(base_url) or ""
    domain = "api.minimax.io" if "minimax.io" in host else "api.minimaxi.com"
    url = f"https://{domain}/v1/api/openplatform/coding_plan/remains"

    payload, error = fetch(url, api_key)
    return error or parse_minimax(payload)


def parse_minimax(payload):
    """与网络请求分离，便于不联网单测（见 selftest_usage.py）"""
    payload = payload or {}
    base_resp = payload.get("base_resp") or {}
    status_code = base_resp.get("status_code")
    if status_code not in (0, None):
        msg = base_resp.get("status_msg") or "未知错误"
        return failure(f"业务错误 (code {status_code}): {msg}")

    items = payload.get("model_remains")
    if not isinstance(items, list):
        return failure("响应里没有 model_remains")

    general = next((i for i in items if (i or {}).get("model_name") == "general"), None)
    if general is None:
        return failure("model_remains 里没有 general 条目（只有 video 等非编程模型）")

    windows = []

    interval = parse_number(general, "current_interval_remaining_percent")
    if interval is not None:
        windows.append({
            "label": "5 小时",
            "used_percent": 100.0 - interval,
            "resets_at": millis_to_local(general.get("end_time")),
        })

    if general.get("current_weekly_status") == 1:
        weekly = parse_number(general, "current_weekly_remaining_percent")
        if weekly is not None:
            windows.append({
                "label": "7 天",
                "used_percent": 100.0 - weekly,
                "resets_at": millis_to_local(general.get("weekly_end_time")),
            })

    if not windows:
        return failure("general 条目里没有可用的百分比字段")

    return quota(windows)


# ============================================================ 汇总

def discover():
    """
    从配置里找出所有渠道及其上游地址，返回 {渠道名: [base_urls]}。

    routes 与 aggregate.targets 都算 —— 只用路径前缀、没配聚合路由的用户
    也该能查余额（把 key 加进 ai_keys.json 即可）。
    同名时以 aggregate.targets 为准，它的地址更完整（含协议私有前缀）。
    """
    config = read_domains_file()
    found = {}

    for prefix, domain in (config.get("routes") or {}).items():
        if str(prefix).startswith("_"):
            continue
        found[str(prefix).lstrip("/")] = [str(domain)]

    aggregate = load_aggregate(config)
    if aggregate:
        for name, conf in aggregate["targets"].items():
            urls = [v for k, v in conf.items() if k in ("openai", "anthropic") and v]
            if urls:
                found[name] = urls

    return found


def collect():
    """查询所有能查的渠道，返回归一化结果"""
    keys = load_keys()
    result = {
        "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "targets": {},
        # 域名没匹配上内置提供方的渠道：不进 targets、不展示，
        # 只在这里留个名字供 --json 的使用者自行判断
        "skipped": [],
    }

    for name, base_urls in discover().items():
        entry = find_provider(base_urls)
        if entry is None:
            result["skipped"].append(name)
            continue

        api_key = keys.get(name)
        if not api_key:
            # 与"不支持"区别对待：这是可修的配置问题，静默掉用户会以为是 bug
            result["targets"][name] = failure(
                f"ai_keys.json 里缺少 {name} 的 key"
            )
            result["targets"][name]["provider"] = entry["id"]
            continue

        try:
            # 传**第一个**地址，不是把多个拼成一串。
            #
            # 一个渠道有多个端点时（openai + anthropic 各一个 base），拼起来会得到
            # "https://a.com https://b.com" 这种带空格的伪 URL；第三方实现照
            # provider() 的承诺拿它去拼请求地址，拼出来的东西是坏的。
            # 多个端点本来就是同一家的不同协议入口，主机名相同，取第一个即可。
            queried = entry["query"](api_key, base_urls[0])
        except Exception as e:
            # 第三方自己加的提供方抛异常时，不能让整个查询崩掉
            queried = failure(f"提供方 {entry['id']} 实现抛出异常: {type(e).__name__}: {e}")
        queried["provider"] = entry["id"]
        result["targets"][name] = queried

    return result


# ============================================================ 展示

NAME_COL = 12
VALUE_COL = 28


def display_width(text):
    """
    字符串在等宽终端里占的列数。

    ⚠️ 不能用 len()：中日韩字符宽度是 2 列，按字符数补空格会让含中文的列
    整体右移、表格参差。按 east_asian_width 判定，W（宽）与 F（全角）算 2。
    """
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def pad(text, columns):
    """按显示宽度左对齐补足到 columns 列"""
    return text + " " * max(columns - display_width(text), 0)


SYMBOLS = {"CNY": "¥", "USD": "$", "EUR": "€"}


def render(result):
    lines = []
    width = 2 + NAME_COL + VALUE_COL + 18
    lines.append("=" * width)
    lines.append(f"渠道剩余额度　{result['updated_at']}")
    lines.append("=" * width)

    if not result["targets"]:
        lines.append("  没有可查询额度的渠道。")
        lines.append("  内置支持：" + "、".join(p["id"] for p in PROVIDERS))
        lines.append("  其他渠道需要自行实现，见 balance.py 里的 @provider 说明。")
        return "\n".join(lines)

    lines.append("  " + pad("渠道", NAME_COL) + pad("额度", VALUE_COL) + "重置")
    lines.append("  " + "─" * (width - 4))

    def row(name, value, tail=""):
        lines.append("  " + pad(name, NAME_COL) + pad(value, VALUE_COL) + tail)

    for name, entry in result["targets"].items():
        kind = entry["kind"]

        if kind == "currency":
            for i, b in enumerate(entry["balances"]):
                symbol = SYMBOLS.get(b["currency"], b["currency"] + " ")
                total = b["total"]
                amount = f"{symbol}{total:.2f}" if total is not None else "解析失败"
                # 货币余额没有重置概念 —— 只能充值，不会自己回升
                row(name if i == 0 else "", amount, "—")
            if not entry.get("is_available", True):
                row("", "⚠️ 上游标记余额不足")

        elif kind == "quota":
            for i, w in enumerate(entry["windows"]):
                value = pad(w["label"], 7) + f"已用 {w['used_percent']:.0f}%"
                row(name if i == 0 else "", value, w["resets_at"] or "—")

        else:
            tag = "（可重试）" if entry.get("transient") else ""
            row(name, "查询失败" + tag, entry["error"][:40])

    return "\n".join(lines)


def one_line(result):
    """
    单行摘要，供 stats_report.py 复用。
    单行放不下重置时间，需要细节的看 balance.py 本体。
    """
    parts = []
    for name, entry in (result.get("targets") or {}).items():
        if entry["kind"] == "currency":
            for b in entry["balances"]:
                if b["total"] is not None:
                    symbol = SYMBOLS.get(b["currency"], "")
                    parts.append(f"{name} {symbol}{b['total']:.2f}")
        elif entry["kind"] == "quota":
            # 单行里必须写清"已用"，否则 1% 会被读成"只剩 1%"，语义正好反过来
            windows = " ".join(
                f"{w['label']}{w['used_percent']:.0f}%" for w in entry["windows"]
            )
            parts.append(f"{name} 已用 {windows}")
    return "　·　".join(parts)


def lowest_currency(result):
    """最低的货币余额，用于阈值告警。没有货币类渠道时返回 None。"""
    values = [
        b["total"]
        for entry in (result.get("targets") or {}).values()
        if entry["kind"] == "currency"
        for b in entry["balances"]
        if b["total"] is not None
    ]
    return min(values) if values else None


def main():
    parser = argparse.ArgumentParser(description="查询各渠道剩余额度")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--line", action="store_true", help="只输出单行摘要")
    parser.add_argument("--providers", action="store_true", help="列出已内置的提供方")
    parser.add_argument(
        "--min", type=float, metavar="N",
        help="任一货币余额低于 N 则以退出码 1 结束（挂 cron 做告警用）",
    )
    args = parser.parse_args()

    if args.providers:
        print("已内置的额度提供方：")
        for p in PROVIDERS:
            print(f"  {p['id']:<12}匹配域名: {'、'.join(p['domains'])}")
        print("\n其他渠道需自行实现，见本文件顶部说明与 @provider 装饰器。")
        return 0

    result = collect()

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.line:
        print(one_line(result))
    else:
        print(render(result))

    if args.min is not None:
        lowest = lowest_currency(result)
        if lowest is not None and lowest < args.min:
            if not args.json:
                print(f"\n⚠️ 最低余额 {lowest:.2f} 低于阈值 {args.min:.2f}")
            return 1

    failed = [n for n, e in (result.get("targets") or {}).items() if e["kind"] == "error"]
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
