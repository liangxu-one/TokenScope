#!/usr/bin/env python3
"""
归一化与聚合路由的回归自测。纯 stdlib assert，不引依赖、不需要测试框架。

    python3 selftest_usage.py

为什么需要它：token 归一化是这个项目的正确性核心，而各家 usage 的语义差异
（谁含缓存、谁不含）此前只以注释形式存在。改错一处不会报错、不会崩，只会让
界面上的数字静静地偏掉几万——这类问题肉眼发现不了。这里把每条结论钉成断言。

⚠️ 断言里的期望值不要"顺手改成实际输出"。每条都标注了依据来源，
改动前先回去核对那个来源。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from http_proxy import ProxyHandler, extract_stream_error  # noqa: E402

FAILURES = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  ✅ {label}")
    else:
        print(f"  ❌ {label}\n       期望: {expected}\n       实际: {actual}")
        FAILURES.append(label)


def tokens(new_input, cached, cache_creation, output):
    """按 empty_tokens() 的字段顺序构造期望值，省得每处写一遍长字典"""
    return {
        "new_input_tokens": new_input,
        "cached_tokens": cached,
        "cache_creation_tokens": cache_creation,
        "output_tokens": output,
    }


# ---------------------------------------------------------------- 语义识别

def test_semantic_detection():
    print("\n[1] usage 语义识别（detect_usage_semantic）")
    detect = ProxyHandler.detect_usage_semantic

    check(
        "input_tokens 单独出现 → anthropic（不含缓存，无需减法）",
        detect({"input_tokens": 100, "output_tokens": 10}),
        "anthropic",
    )
    check(
        "prompt_tokens 单独出现 → openai（已含缓存，需减法）",
        detect({"prompt_tokens": 100, "completion_tokens": 10}),
        "openai",
    )
    check(
        "input_tokens_details 存在 → openai-responses（名字像 anthropic，语义是 openai）",
        detect({"input_tokens": 100, "input_tokens_details": {"cached_tokens": 30}}),
        "openai-responses",
    )
    # README「流式 usage 的合并规则」记录的实测形态：有网关会让两种风格的缓存字段
    # 并存，只有输入总量字段是互斥可靠的。这条防止有人再用缓存字段名去判断语义。
    check(
        "混合形态（cache_read_input_tokens 与 prompt_tokens_details 并存）→ 仍按输入总量字段判",
        detect({
            "input_tokens": 6,
            "cache_read_input_tokens": 24000,
            "prompt_tokens_details": {"cached_tokens": 24000},
        }),
        "anthropic",
    )
    check(
        "两个总量字段都有 → 取数值更大的那个的口径（含缓存的必然更大）",
        detect({"input_tokens": 100, "prompt_tokens": 500}),
        "openai",
    )
    check("空 usage → None（交给调用方按路径兜底）", detect({}), None)


# ---------------------------------------------------------------- 归一化

def test_anthropic():
    print("\n[2] Anthropic：input_tokens 不含缓存，不做减法")
    usage = {
        "input_tokens": 1000,
        "cache_read_input_tokens": 20000,
        "cache_creation_input_tokens": 500,
        "output_tokens": 300,
    }
    check(
        "四项原样取用",
        ProxyHandler.normalize_usage(usage, "anthropic"),
        tokens(1000, 20000, 500, 300),
    )

    # 对齐 new-api cacheCreationTokensForOpenAIUsage()：部分网关把缓存写入拆成
    # 5m/1h 两档，聚合值与拆分值取较大者
    check(
        "缓存写入拆成 5m/1h 时取拆分总和（大于聚合值）",
        ProxyHandler.normalize_usage({
            "input_tokens": 10,
            "cache_creation_input_tokens": 100,
            "cache_creation": {
                "ephemeral_5m_input_tokens": 300,
                "ephemeral_1h_input_tokens": 200,
            },
            "output_tokens": 5,
        }, "anthropic"),
        tokens(10, 0, 500, 5),
    )


def test_chat_completions():
    print("\n[3] OpenAI Chat Completions：prompt_tokens 已含缓存，减 cached")
    check(
        "prompt_tokens_details.cached_tokens 被减掉",
        ProxyHandler.normalize_usage({
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "prompt_tokens_details": {"cached_tokens": 300},
        }, "openai"),
        tokens(700, 300, 0, 200),
    )
    check(
        "DeepSeek 的 prompt_cache_hit_tokens 同样识别",
        ProxyHandler.normalize_usage({
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "prompt_cache_hit_tokens": 400,
        }, "openai"),
        tokens(600, 400, 0, 200),
    )


def test_responses():
    print("\n[4] OpenAI Responses：input_tokens 含 cache_read + cache_write，两项都减")
    # 依据：cc-switch src-tauri/src/proxy/usage/calculator.rs
    #   calculate_with_cache_semantics()：
    #   input_tokens.saturating_sub(cache_read).saturating_sub(cache_creation)
    # 字段结构依据：openai-python types/responses/response_usage.py
    usage = {
        "input_tokens": 1000,
        "input_tokens_details": {"cached_tokens": 300, "cache_write_tokens": 200},
        "output_tokens": 500,
        "output_tokens_details": {"reasoning_tokens": 120},
        "total_tokens": 1500,
    }
    result = ProxyHandler.normalize_usage(usage, "openai-responses")

    check("1000 - 300(读) - 200(写) = 500 新增输入", result, tokens(500, 300, 200, 500))
    # 这条是整个 Responses 支持的核心不变量：归一化后的总输入必须等于上游报的
    # input_tokens，否则命中率分母就不再是「上游声称的总输入」，与项目口径脱节
    check(
        "总输入守恒：new + cached + creation == 上游的 input_tokens",
        result["new_input_tokens"] + result["cached_tokens"] + result["cache_creation_tokens"],
        1000,
    )
    check(
        "reasoning_tokens 不另加（已计入 output_tokens）",
        result["output_tokens"],
        500,
    )

    check(
        "网关省略 cache_write_tokens 时只减 cached",
        ProxyHandler.normalize_usage({
            "input_tokens": 1000,
            "input_tokens_details": {"cached_tokens": 300},
            "output_tokens": 50,
        }, "openai-responses"),
        tokens(700, 300, 0, 50),
    )
    # saturating_sub 语义：字段互相矛盾时宁可算 0，绝不能出负数把汇总值拉低
    check(
        "缓存之和大于 input_tokens（上游数据矛盾）时截到 0，不出负数",
        ProxyHandler.normalize_usage({
            "input_tokens": 100,
            "input_tokens_details": {"cached_tokens": 300, "cache_write_tokens": 50},
            "output_tokens": 10,
        }, "openai-responses"),
        tokens(0, 300, 50, 10),
    )
    check(
        "网关在 /responses 上返回 Chat Completions 形态时，按字段判断仍正确减法",
        ProxyHandler.normalize_usage({
            "prompt_tokens": 800,
            "completion_tokens": 100,
            "prompt_tokens_details": {"cached_tokens": 200},
        }, "openai-responses"),
        tokens(600, 200, 0, 100),
    )


# ------------------------------------------------------------ 协议格式识别

def test_api_format():
    print("\n[5] 协议格式识别（detect_api_format）")
    detect = ProxyHandler.detect_api_format

    check("/v1/messages → anthropic", detect("/deepseek/anthropic/v1/messages?beta=true"), "anthropic")
    check("/v1/chat/completions → openai", detect("/minimax/v1/chat/completions"), "openai")
    check("/v1/responses → openai-responses", detect("/auto/v1/responses"), "openai-responses")
    # /responses 必须比 anthropic 先判，否则这种网关路径会被误判
    check(
        "/anthropic/v1/responses → openai-responses（/responses 优先于 anthropic）",
        detect("/gw/anthropic/v1/responses"),
        "openai-responses",
    )


# -------------------------------------------------------------- 流式解析

class _Fake(ProxyHandler):
    """只借用 ProxyHandler 的解析方法，不建真实连接（__init__ 会去读 socket）"""

    def __init__(self):
        pass

    def log_message(self, fmt, *args):
        pass


def test_stream_parsing():
    print("\n[6] 流式 SSE 解析（parse_sse_line）")
    handler = _Fake()

    # Responses API：usage 嵌在 response 对象里，不在事件顶层。
    # 依据 openai-python response_completed_event.py: ResponseCompletedEvent{response: Response}
    acc = ProxyHandler.empty_tokens()
    events = [
        '{"type":"response.created","sequence_number":0,'
        '"response":{"id":"resp_1","model":"gpt-5.2","usage":null}}',
        '{"type":"response.output_text.delta","sequence_number":1,"delta":"hi"}',
        '{"type":"response.completed","sequence_number":2,"response":{"id":"resp_1",'
        '"model":"gpt-5.2","usage":{"input_tokens":1000,'
        '"input_tokens_details":{"cached_tokens":300,"cache_write_tokens":200},'
        '"output_tokens":42}}}',
    ]
    resolved_model = None
    for raw in events:
        found = handler.parse_sse_line(f"data: {raw}", acc, "openai-responses")
        if found:
            resolved_model = found

    check("从嵌套 response 里取到 usage（不再静默记 0）", acc, tokens(500, 300, 200, 42))
    check("从 response.created 就解析出 model", resolved_model, "gpt-5.2")

    # response.incomplete 也是终态事件，usage 同样权威。
    # 这不是理论情况：实测 DeepSeek 的流式 Responses 在 max_output_tokens 截断时
    # 发的就是 incomplete 而不是 completed —— 只认 completed 会让这类请求记 0 token。
    acc = ProxyHandler.empty_tokens()
    handler.parse_sse_line(
        'data: {"type":"response.incomplete","sequence_number":9,'
        '"response":{"id":"resp_2","model":"deepseek-v4-flash",'
        '"incomplete_details":{"reason":"max_output_tokens"},'
        '"usage":{"input_tokens":85,"input_tokens_details":{"cached_tokens":0},'
        '"output_tokens":16,"output_tokens_details":{"reasoning_tokens":14}}}}',
        acc, "openai-responses",
    )
    check("response.incomplete 的 usage 也被当作权威终值", acc, tokens(85, 0, 0, 16))
    check(
        "reasoning_tokens 不额外累加到 output（已含在 output_tokens 里）",
        acc["output_tokens"],
        16,
    )

    # 回归：Anthropic 两段式 usage —— message_delta 是权威终值必须覆盖，
    # 不能取 max，否则新增输入被高估上万、命中率被严重低估。
    # 数值取自 README「流式 usage 的合并规则」记录的实测样本（start 给粗估 24681，
    # delta 才是真值 6）。模型名无关紧要，断言只看 token。
    acc = ProxyHandler.empty_tokens()
    handler.parse_sse_line(
        'data: {"type":"message_start","message":{"model":"two-phase-usage-model",'
        '"usage":{"input_tokens":24681,"cache_read_input_tokens":0}}}',
        acc, "anthropic",
    )
    handler.parse_sse_line(
        'data: {"type":"message_delta",'
        '"usage":{"input_tokens":6,"cache_read_input_tokens":24675,"output_tokens":88}}',
        acc, "anthropic",
    )
    check(
        "message_delta 权威覆盖 message_start 的粗估（不是取 max）",
        acc,
        tokens(6, 24675, 0, 88),
    )

    # 回归：OpenAI 流式最后一个 chunk 带 usage
    acc = ProxyHandler.empty_tokens()
    handler.parse_sse_line('data: {"choices":[{"delta":{"content":"x"}}],"usage":null}', acc, "openai")
    handler.parse_sse_line(
        'data: {"choices":[],"usage":{"prompt_tokens":500,"completion_tokens":60,'
        '"prompt_tokens_details":{"cached_tokens":100}}}',
        acc, "openai",
    )
    check("OpenAI 末尾 chunk 的 usage 生效，且 usage:null 的 chunk 不误判", acc, tokens(400, 100, 0, 60))


def test_stream_errors():
    print("\n[7] 流内错误提取（extract_stream_error）")

    check(
        "正常 chunk 带 error:null 不算失败（用真值判断而非 'error' in event）",
        extract_stream_error({"choices": [], "error": None}),
        None,
    )
    check(
        "Anthropic 流内错误",
        extract_stream_error({"type": "error", "error": {"type": "overloaded_error", "message": "overloaded"}}),
        "overloaded_error: overloaded",
    )
    check(
        "OpenAI 兼容流内错误",
        extract_stream_error({"error": {"message": "rate limited", "code": "429"}}),
        "429: rate limited",
    )
    # Responses API 把 error 也嵌在 response 里。不认这层的话，一次失败的
    # Responses 流会被记成 status=200、零输出的"干净成功"，jsonl 里毫无线索
    check(
        "Responses 的 response.failed（error 嵌在 response 里）",
        extract_stream_error({
            "type": "response.failed",
            "response": {"id": "resp_1", "error": {"code": "server_error", "message": "boom"}},
        }),
        "server_error: boom",
    )
    check(
        "response.completed 不带 error 时不误报",
        extract_stream_error({"type": "response.completed", "response": {"id": "r", "usage": {}}}),
        None,
    )


# -------------------------------------------------------------- 聚合路由

# 刻意用通用的 target 名而不是某人的真实渠道清单：这里要覆盖的是三种**配置形态**
#   both-protocols  两个协议都配 —— 正常路径
#   openai-only     只配 openai   —— 验证 Responses 走 openai 桶
#   anthropic-only  只配 anthropic —— 验证「缺该协议端点」要报错
# 换渠道、加减渠道都不该动这个 fixture。
AGGREGATE_FIXTURE = {
    "aggregate": {
        "prefix": "/auto",
        "targets": {
            "deepseek": {
                "openai": "https://api.deepseek.com",
                "anthropic": "https://api.deepseek.com/anthropic",
            },
            "minimax": {
                "openai": "https://api.minimaxi.com",
                "anthropic": "https://api.minimaxi.com/anthropic",
            },
            "openai-only": {"openai": "https://openai-only.example.com/v1-compat"},
            "anthropic-only": {"anthropic": "https://anthropic-only.example.com/api/anthropic"},
        },
        "models": {
            # 精确匹配指向与 deepseek-* 不同的 target，才能证明精确优先于通配
            "deepseek-v4-flash": "minimax",
            "deepseek-*": "deepseek",
            "MiniMax-*": "minimax",
            "resp-*": "openai-only",
            "claude-*": "anthropic-only",
        },
        "default": "deepseek",
    }
}


def test_model_matching():
    print("\n[8] 模型 → target 匹配（match_model）")
    from http_proxy import load_aggregate

    original = ProxyHandler.aggregate
    ProxyHandler.aggregate = load_aggregate(AGGREGATE_FIXTURE)
    try:
        match = ProxyHandler.match_model
        check("精确匹配优先于通配（写在通配后面也一样）", match("deepseek-v4-flash"), "minimax")
        check("通配匹配", match("deepseek-v4-pro"), "deepseek")
        check("大小写敏感：MiniMax-M3 命中 MiniMax-*", match("MiniMax-M3"), "minimax")
        # fnmatchcase 而非 fnmatch：后者在 macOS 上会折叠大小写导致误命中
        check("大小写敏感：minimax-m3 不命中 MiniMax-*，落到 default", match("minimax-m3"), "deepseek")
        check("claude-* → anthropic-only", match("claude-opus-5"), "anthropic-only")
        check("都不命中 → default", match("gpt-nonexistent"), "deepseek")

        no_default = load_aggregate(AGGREGATE_FIXTURE)
        no_default["default"] = None
        ProxyHandler.aggregate = no_default
        check("无 default 时返回 None（调用方转 400）", ProxyHandler.match_model("gpt-x"), None)
    finally:
        ProxyHandler.aggregate = original


def test_aggregate_routing():
    print("\n[9] 聚合路由拼接与错误（resolve_aggregate）")
    from http_proxy import AggregateRouteError, load_aggregate

    handler = _Fake()
    original_aggregate, original_keys = ProxyHandler.aggregate, ProxyHandler.keys
    ProxyHandler.aggregate = load_aggregate(AGGREGATE_FIXTURE)
    ProxyHandler.keys = {
        "deepseek": "sk-ds", "minimax": "sk-mm",
        "openai-only": "sk-oo", "anthropic-only": "sk-ao",
    }

    def route(path, model, api_format):
        return handler.resolve_aggregate(path, "/auto", model, api_format)

    try:
        # base 拼接的形态取自现有 jsonl 的真实路径：渠道私有前缀在 base 里，
        # 客户端给的标准协议路径直接追加在后面
        check(
            "anthropic 协议拼上渠道私有前缀，且保留 query string",
            route("/auto/v1/messages?beta=true", "claude-opus-5", "anthropic"),
            ("anthropic-only",
             "https://anthropic-only.example.com/api/anthropic/v1/messages?beta=true",
             {"key": "sk-ao", "style": "anthropic"}),
        )
        check(
            "openai 协议拼接",
            route("/auto/v1/chat/completions", "deepseek-v4-pro", "openai"),
            ("deepseek", "https://api.deepseek.com/v1/chat/completions",
             {"key": "sk-ds", "style": "openai"}),
        )
        check(
            "Responses 走 openai 端点（BUCKET_FOR_FORMAT 映射）",
            route("/auto/v1/responses", "resp-model", "openai-responses"),
            ("openai-only", "https://openai-only.example.com/v1-compat/v1/responses",
             {"key": "sk-oo", "style": "openai"}),
        )
        check(
            "anthropic 协议下 MiniMax-* 命中 minimax",
            route("/auto/v1/messages", "MiniMax-M3", "anthropic"),
            ("minimax", "https://api.minimaxi.com/anthropic/v1/messages",
             {"key": "sk-mm", "style": "anthropic"}),
        )
        check(
            "provider 是 target 名而不是 auto（保证渠道维度仍是真实上游）",
            route("/auto/v1/messages", "claude-opus-5", "anthropic")[0],
            "anthropic-only",
        )
        check(
            "剥完前缀为空时补上 /",
            route("/auto", "deepseek-v4-pro", "openai")[1],
            "https://api.deepseek.com/",
        )

        def expect_error(label, path, model, api_format, keyword):
            try:
                route(path, model, api_format)
            except AggregateRouteError as e:
                check(label, keyword in str(e), True)
            else:
                check(label, "没有抛异常", f"应抛 AggregateRouteError 且含 {keyword!r}")

        expect_error(
            "target 缺该协议端点 → 报错而不是转发到错地址",
            "/auto/v1/chat/completions", "claude-opus-5", "openai", "未配置",
        )
        expect_error(
            "反向：只配 openai 的 target 收到 anthropic 请求也报错",
            "/auto/v1/messages", "resp-model", "anthropic", "未配置",
        )

        # 把 anthropic-only 的 key 摘掉再试，验证缺 key 这条路径
        ProxyHandler.keys = {"deepseek": "sk-ds", "minimax": "sk-mm"}
        expect_error(
            "缺 key → 报错并指出是哪个 target",
            "/auto/v1/messages", "claude-opus-5", "anthropic", "anthropic-only",
        )
    finally:
        ProxyHandler.aggregate, ProxyHandler.keys = original_aggregate, original_keys


def test_key_injection():
    print("\n[10] 密钥注入（build_upstream_headers）")

    class _HeaderFake(_Fake):
        def __init__(self, headers):
            self.headers = headers

    client_headers = {
        "Authorization": "Bearer placeholder-from-client",
        "x-api-key": "placeholder-from-client",
        "Content-Type": "application/json",
        "Connection": "keep-alive",
    }

    # auth=None 必须与加聚合特性之前逐字相同：客户端凭证原样透传
    passthrough = _HeaderFake(dict(client_headers)).build_upstream_headers(10, auth=None)
    check("auth=None 时透传客户端 Authorization", passthrough.get("Authorization"), "Bearer placeholder-from-client")
    check("auth=None 时透传客户端 x-api-key", passthrough.get("x-api-key"), "placeholder-from-client")
    check("逐跳头被剔除", "Connection" in passthrough, False)

    anthropic = _HeaderFake(dict(client_headers)).build_upstream_headers(
        10, auth={"key": "sk-real", "style": "anthropic"}
    )
    check("anthropic 风格注入 x-api-key", anthropic.get("x-api-key"), "sk-real")
    check("客户端的占位 Authorization 被剔除（避免两套凭证）", "Authorization" in anthropic, False)
    check("缺 anthropic-version 时补默认值", anthropic.get("anthropic-version"), "2023-06-01")

    with_version = _HeaderFake({"anthropic-version": "2024-10-22"}).build_upstream_headers(
        10, auth={"key": "sk-real", "style": "anthropic"}
    )
    check("客户端已带 anthropic-version 则不覆盖", with_version.get("anthropic-version"), "2024-10-22")

    openai = _HeaderFake(dict(client_headers)).build_upstream_headers(
        10, auth={"key": "sk-real", "style": "openai"}
    )
    check("openai 风格注入 Bearer", openai.get("Authorization"), "Bearer sk-real")
    check("客户端的占位 x-api-key 被剔除", "x-api-key" in openai, False)


def test_include_usage_injection():
    print("\n[11] include_usage 注入范围（build_upstream_body）")
    handler = _Fake()

    def body_for(api_format, payload):
        raw = json.dumps(payload).encode("utf-8")
        out, model, is_stream = handler.build_upstream_body(raw, api_format)
        return json.loads(out), model, is_stream

    out, model, is_stream = body_for("openai", {"model": "deepseek-v4-pro", "stream": True})
    check("Chat Completions 流式注入 include_usage", out.get("stream_options"), {"include_usage": True})
    check("model 解析", model, "deepseek-v4-pro")
    check("stream 解析", is_stream, True)

    # 关键回归：Responses 版 stream_options 只有 include_obfuscation，
    # 注入 include_usage 是非法嵌套参数，上游直接 400
    out, _, _ = body_for("openai-responses", {"model": "gpt-5.2", "stream": True})
    check("Responses 流式绝不注入 stream_options（否则上游 400）", "stream_options" in out, False)

    out, _, _ = body_for("anthropic", {"model": "claude-opus-5", "stream": True})
    check("anthropic 流式不注入", "stream_options" in out, False)

    out, _, _ = body_for("openai", {"model": "x", "stream": False})
    check("非流式不注入", "stream_options" in out, False)


# -------------------------------------------------------------- 额度解析

def test_balance_parsing():
    print("\n[12] 额度解析（balance.py）")
    from balance import PROVIDERS, find_provider, parse_deepseek, parse_minimax

    # DeepSeek：金额是**字符串**。这条是防静默错误的关键 —— 当成数字取会得到
    # None、余额显示 0，界面上完全看不出来。真实响应就是这个形状。
    result = parse_deepseek({
        "is_available": True,
        "balance_infos": [{"currency": "CNY", "total_balance": "10.73",
                           "granted_balance": "0.00", "topped_up_balance": "10.73"}],
    })
    check("字符串金额被正确解析成数字", result["balances"][0]["total"], 10.73)
    check("kind 为 currency", result["kind"], "currency")
    check("币种", result["balances"][0]["currency"], "CNY")
    # 上面的 fixture 刻意保留了这两个字段（DeepSeek 真会返回），断言的是**不收**：
    # granted + topped_up 恒等于 total，是同一笔钱的两种切法，多存一份就会漂移。
    check("赠金/充值不进结果（与 total 冗余）",
          set(result["balances"][0]) & {"granted", "topped_up"}, set())
    check("balance 只有币种与总额两个键",
          sorted(result["balances"][0]), ["currency", "total"])

    check(
        "多币种账户各自独立成条（不能相加）",
        len(parse_deepseek({"balance_infos": [
            {"currency": "CNY", "total_balance": "10.73"},
            {"currency": "USD", "total_balance": "2.00"},
        ]})["balances"]),
        2,
    )
    check(
        "is_available=false 被带出来",
        parse_deepseek({"is_available": False,
                        "balance_infos": [{"currency": "CNY", "total_balance": "0"}]})["is_available"],
        False,
    )
    check("缺 balance_infos → 失败而不是空结果",
          parse_deepseek({"is_available": True})["kind"], "error")

    # MiniMax：三个坑。响应样例取自实测（见 balance.py 里的说明）
    body = {
        "model_remains": [
            {"model_name": "general",
             "current_interval_remaining_percent": 99,
             "current_weekly_remaining_percent": 77,
             "current_interval_status": 1, "current_weekly_status": 1,
             "end_time": 1785672000000, "weekly_end_time": 1785686400000},
            # video 百分比恒 100，混进去会把数字冲淡
            {"model_name": "video",
             "current_interval_remaining_percent": 100,
             "current_weekly_remaining_percent": 100,
             "current_interval_status": 3, "current_weekly_status": 3},
        ],
        "base_resp": {"status_code": 0, "status_msg": "success"},
    }
    result = parse_minimax(body)
    check("kind 为 quota（没有金额）", result["kind"], "quota")
    check("只取 general，跳过 video", len(result["windows"]), 2)
    # 上游给的是「剩余」99 / 77，本模块统一存「已用」，必须反转成 1 / 23。
    # 方向搞反不会报错，只会把 1% 显示成 99% —— 这是最容易犯又最难发现的错。
    check("5 小时窗：剩余 99 → 已用 1", result["windows"][0]["used_percent"], 1)
    check("7 天窗：剩余 77 → 已用 23", result["windows"][1]["used_percent"], 23)
    # 标签叫「7 天」不叫「周」：实测该窗口跨度恰好 604800000ms（7×24h），
    # 是滚动 7 天窗而非自然周，叫「周」会让人以为周一清零
    check("窗口标签", [w["label"] for w in result["windows"]], ["5 小时", "7 天"])
    check("重置时间被解析", result["windows"][0]["resets_at"] is not None, True)
    check("不同时存剩余字段（避免两份漂移）",
          "remaining_percent" in result["windows"][0], False)

    # 无该限额的套餐：status=3 且剩余恒 100（已用 0），展示出来是假信息
    no_weekly = json.loads(json.dumps(body))
    no_weekly["model_remains"][0]["current_weekly_status"] = 3
    no_weekly["model_remains"][0]["current_weekly_remaining_percent"] = 100
    check(
        "current_weekly_status != 1 时不展示 7 天窗（否则是假的已用 0%）",
        len(parse_minimax(no_weekly)["windows"]),
        1,
    )

    # HTTP 200 也可能是业务失败
    check(
        "base_resp.status_code != 0 判为失败（即便 HTTP 200）",
        parse_minimax({"base_resp": {"status_code": 1004, "status_msg": "auth failed"},
                       "model_remains": []})["kind"],
        "error",
    )
    check(
        "只有 video 没有 general → 失败而不是空",
        parse_minimax({"model_remains": [{"model_name": "video",
                                          "current_interval_remaining_percent": 100}],
                       "base_resp": {"status_code": 0}})["kind"],
        "error",
    )

    # 注册表：域名匹配
    check("按域名找到 deepseek",
          find_provider(["https://api.deepseek.com/anthropic"])["id"], "deepseek")
    check("按域名找到 minimax（国内站）",
          find_provider(["https://api.minimaxi.com"])["id"], "minimax")
    check("按域名找到 minimax（国际站）",
          find_provider(["https://api.minimax.io"])["id"], "minimax")
    # 认不出的渠道必须返回 None，由调用方静默跳过 —— 不能瞎猜成某一家。
    # 用途最广的一类就是自建/私有网关：它们没有公开的额度接口，理应完全不显示。
    check("认不出的域名返回 None",
          find_provider(["https://llm-gateway.internal.example.com/api/anthropic"]), None)
    check("已内置两家", sorted(p["id"] for p in PROVIDERS), ["deepseek", "minimax"])


def main():
    print("=" * 68)
    print("TokenScope 归一化 / 路由自测")
    print("=" * 68)

    test_semantic_detection()
    test_anthropic()
    test_chat_completions()
    test_responses()
    test_api_format()
    test_stream_parsing()
    test_stream_errors()
    test_model_matching()
    test_aggregate_routing()
    test_key_injection()
    test_include_usage_injection()
    test_balance_parsing()

    print("\n" + "=" * 68)
    if FAILURES:
        print(f"❌ {len(FAILURES)} 项失败：")
        for name in FAILURES:
            print(f"   - {name}")
        return 1
    print("✅ 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
