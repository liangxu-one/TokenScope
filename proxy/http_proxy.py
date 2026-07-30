#!/usr/bin/env python3
"""
HTTP 反向代理：拦截大模型 API 请求和响应，解析 token 使用情况

无需安装证书，客户端只需将 base URL 改为 http://localhost:12345/<provider>

统计数据按天写入 ai_stats-YYYY-MM-DD.jsonl，每行一条 JSON 记录。

--------------------------------------------------------------------------------
token 归一化口径（对齐 new-api）
--------------------------------------------------------------------------------
各家原始语义不一致，必须先归一化：

    Anthropic 格式：input_tokens 不含缓存
        new_input = input_tokens
    OpenAI 格式：prompt_tokens 已含缓存，需相减
        new_input = prompt_tokens - cached_tokens

写入文件的字段：
    new_input_tokens      纯新增输入（不含缓存）
    cached_tokens         缓存读取（命中）
    cache_creation_tokens 缓存写入（首次建缓存的开销）
    output_tokens         输出
    total_input_tokens    new_input + cached + cache_creation（真实总输入）
    total_tokens          total_input + output
    hit_rate_denominator  命中率分母，当前等于 total_input_tokens

--------------------------------------------------------------------------------
缓存命中率
--------------------------------------------------------------------------------
必须先汇总再相除（pooled ratio），**绝不能每条单独算再取平均**——
否则一条几百 token 的请求会和一条十万 token 的请求权重相同。

    命中率 = Σ cached_tokens / Σ total_input_tokens
           = Σ cached / Σ (new_input + cached + cache_creation)

分母**包含 cache_creation_tokens**，回答的问题是
「全部输入 token 里，有多少是靠缓存复用的」。

⚠️ 此口径与 new-api 不同，是刻意选择，勿"修正"回去。
new-api 的分母只含 new_input + cached（见 ChannelAffinityUsageCacheModal.jsx:41-51），
回答的是「本可命中的部分命中了多少」，同一份数据下会得出高得多的数字
（实测 98% vs 65%）。两者都不算错，只是问的问题不同：

    new-api 口径：衡量缓存机制的效率
    本项目口径：衡量总输入的缓存复用程度，建缓存的开销也计入分母

副作用：首次建缓存的请求（cache_creation 很大而 cached 为 0）命中率会是 0%，
即便那次建缓存完全正确。这是本口径的固有特性。

分母不含 output_tokens —— 缓存只作用于输入，输出永远不可能命中缓存，
把它计入只会让"输出越多命中率越低"，与缓存效果无关。
"""

import builtins
import gzip
import json
import logging
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.request
import zlib
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer
from logging.handlers import RotatingFileHandler
from socketserver import ThreadingMixIn

# 获取脚本所在目录
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# 配置文件路径（相对路径）
DOMAINS_FILE = os.path.join(SCRIPT_DIR, "ai_stats_domains.json")
STATS_DIR = SCRIPT_DIR
STATS_PREFIX = "ai_stats-"

# model 解析不出来时的占位值。record() 用它判断该不该落盘，
# build_upstream_body() 用它做默认值 —— 两处必须是同一个字符串，所以提到这里。
UNKNOWN_MODEL = "unknown"

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 12345
UPSTREAM_TIMEOUT = 300

# 统计文件保留天数（含今天）。设为 0 则永不清理。
RETENTION_DAYS = int(os.environ.get("AI_PROXY_RETENTION_DAYS", "3"))

# 日志文件与轮转配置。
# 由程序自己持有句柄并轮转，不要用 shell 的 >> 重定向——那样外部截断文件
# 会导致写入偏移错乱（文件看似很大但前面全是空洞）。
LOG_FILE = os.path.join(SCRIPT_DIR, "http_proxy.log")
LOG_MAX_BYTES = int(os.environ.get("AI_PROXY_LOG_MAX_MB", "5")) * 1024 * 1024
LOG_BACKUP_COUNT = int(os.environ.get("AI_PROXY_LOG_BACKUPS", "2"))

# 抓包模式：设置环境变量 AI_PROXY_CAPTURE=1 开启，
# 会把每个请求的完整报文（含原始 SSE 流）写入 captures/ 目录，用于分析各家字段差异。
CAPTURE_ENABLED = os.environ.get("AI_PROXY_CAPTURE", "").lower() not in ("", "0", "false", "no")
CAPTURE_DIR = os.path.join(SCRIPT_DIR, "captures")

# 抓包时需要脱敏的请求头
SENSITIVE_HEADERS = {
    "authorization",
    "x-api-key",
    "api-key",
    "apikey",
    "cookie",
    "set-cookie",
    "proxy-authorization",
    "x-auth-token",
}

# 逐跳（hop-by-hop）头，不允许在代理间转发
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def setup_logging():
    """
    把所有 print 输出同时写到终端和轮转日志文件。

    这里刻意不改造成 logging.info(...) 的调用风格：
    代码里有二十多处 print，逐个替换收益不大，而接管 print 能一次性覆盖，
    也保留了前台运行时直接看终端的习惯。

    轮转由 RotatingFileHandler 负责，它持有文件句柄，达到上限时会
    自动改名（http_proxy.log.1）并新建文件，写入偏移不会错乱。
    """
    handler = RotatingFileHandler(
        LOG_FILE,
        maxBytes=LOG_MAX_BYTES,
        backupCount=LOG_BACKUP_COUNT,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(message)s"))

    logger = logging.getLogger("ai_proxy")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.handlers.clear()
    logger.addHandler(handler)

    original_print = builtins.print
    print_lock = threading.Lock()

    def tee_print(*args, sep=" ", end="\n", file=None, flush=False):
        # 显式指定了 file（如 sys.stderr）的调用不接管，避免干扰异常输出
        if file is not None:
            return original_print(*args, sep=sep, end=end, file=file, flush=flush)

        text = sep.join(str(a) for a in args)
        with print_lock:
            original_print(text, end=end, flush=True)
            for line in text.splitlines() or [""]:
                logger.info(line)
        return None

    builtins.print = tee_print
    return logger


def load_routes():
    """从配置文件加载路由规则"""
    if not os.path.exists(DOMAINS_FILE):
        example = DOMAINS_FILE.replace(".json", ".example.json")
        print(f"[ERROR] 未找到路由配置: {DOMAINS_FILE}")
        if os.path.exists(example):
            print(f"[ERROR] 请复制示例文件后填入真实域名：")
            print(f"        cp {os.path.basename(example)} {os.path.basename(DOMAINS_FILE)}")
        return {}

    try:
        with open(DOMAINS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            # 忽略以下划线开头的键，便于在配置里写注释
            return {
                k: v for k, v in (data.get("routes") or {}).items()
                if not k.startswith("_")
            }
    except Exception as e:
        print(f"[ERROR] 加载路由配置失败: {e}")
        return {}


def stats_file_for(dt):
    """返回指定日期对应的统计文件路径"""
    return os.path.join(STATS_DIR, f"{STATS_PREFIX}{dt.strftime('%Y-%m-%d')}.jsonl")


def purge_old_stats(keep_days=RETENTION_DAYS):
    """
    删除过期的统计文件，只保留最近 keep_days 天（含今天）。

    由代理负责清理，因为它是唯一的写入方；
    读取方（TokenScope）不做任何写/删操作，避免两个进程互相干扰。
    """
    if keep_days <= 0:
        return []

    cutoff = (datetime.now() - timedelta(days=keep_days - 1)).strftime("%Y-%m-%d")
    removed = []

    pattern = re.compile(rf"^{re.escape(STATS_PREFIX)}(\d{{4}}-\d{{2}}-\d{{2}})\.jsonl$")
    try:
        entries = os.listdir(STATS_DIR)
    except OSError:
        return []

    for name in entries:
        matched = pattern.match(name)
        if not matched:
            continue
        # 日期是 ISO 格式，可以直接按字符串比较
        if matched.group(1) < cutoff:
            try:
                os.remove(os.path.join(STATS_DIR, name))
                removed.append(name)
            except OSError:
                pass

    return removed


def mask_secret(value):
    """脱敏敏感头，只保留头尾便于辨认是哪个 key"""
    if not value:
        return value
    text = str(value)
    if len(text) <= 12:
        return f"***(len={len(text)})"
    return f"{text[:8]}…{text[-4:]}(len={len(text)})"


def pretty_json(raw):
    """尽量把字节串格式化成可读 JSON，失败则原样返回文本"""
    if not raw:
        return ""
    if isinstance(raw, bytes):
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return f"<{len(raw)} bytes 非 UTF-8 内容>"
    else:
        text = raw
    try:
        return json.dumps(json.loads(text), ensure_ascii=False, indent=2)
    except ValueError:
        return text


def decode_for_log(raw, content_encoding):
    """
    按 Content-Encoding 解压响应体，**只用于日志与统计记录**。

    代理在 build_upstream_headers 里对每个请求都声明了 Accept-Encoding: gzip, deflate，
    所以上游连错误响应也会压缩。若不解压就 decode，errors="replace" 会把 gzip 字节
    不可逆地替换成 U+FFFD——默认模式下 jsonl 的 error 字段是唯一副本，
    毁了就再也还原不出上游究竟说了什么（限流要等多久、模型名错在哪）。

    与 handle_plain_response 里那段解压刻意不同：这里遇到解不开的编码**不抛异常**。
    成功路径解压失败意味着 token 统计不准，必须落一条 error 让人知道；
    错误路径只是想尽量拿到可读文本，拿不到也不该再造一个新错误去掩盖原始报错。
    """
    encoding = (content_encoding or "").lower()
    try:
        if "gzip" in encoding:
            return gzip.decompress(raw)
        if "deflate" in encoding:
            # 有上游发的是裸 deflate（不带 zlib 头），两种都试一下
            try:
                return zlib.decompress(raw)
            except zlib.error:
                return zlib.decompress(raw, -zlib.MAX_WBITS)
    except Exception:
        # br / zstd 等标准库解不开的编码，或数据本身损坏：原样返回，至少不崩
        pass
    return raw


def extract_stream_error(event):
    """
    从单个 SSE 事件里提取错误描述，没有错误返回 None。

    流式响应的 200 状态头在 body 生成之前就发出去了，上游中途出错时改不了状态码，
    只能在流里塞一个错误事件。认两种形态：

        Anthropic    {"type":"error","error":{"type":"overloaded_error","message":"..."}}
        OpenAI 兼容  {"error":{"message":"...","code":"..."}}

    **必须用真值判断而不是 `"error" in event`**：OpenAI 风格的正常 chunk 里常年带着
    `"error": null`，用 in 判断会把每一条流式请求都标成失败。
    """
    err = event.get("error")
    if not err and (event.get("type") or "") != "error":
        return None

    if isinstance(err, dict):
        message = err.get("message") or json.dumps(err, ensure_ascii=False)
        kind = err.get("type") or err.get("code")
        return f"{kind}: {message}" if kind else str(message)
    if err:
        return str(err)

    # type 是 error 但没有 error 字段：形态不认识，整条留下，别把信息丢了
    return json.dumps(event, ensure_ascii=False)


class Capture:
    """把单次请求的完整报文写成一个易读的文本文件"""

    _seq_lock = threading.Lock()
    _seq = 0

    def __init__(self, provider, method, path):
        with Capture._seq_lock:
            Capture._seq += 1
            seq = Capture._seq

        os.makedirs(CAPTURE_DIR, exist_ok=True)
        stamp = datetime.now().strftime("%H%M%S")
        safe_provider = provider.replace("/", "_") or "unknown"
        self.path = os.path.join(
            CAPTURE_DIR,
            f"{datetime.now().strftime('%Y-%m-%d')}_{stamp}_{seq:03d}_{safe_provider}.txt",
        )
        self.sections = []
        self.add("请求行", f"{method} {path}")

    def add(self, title, body):
        self.sections.append((title, body if body is not None else ""))

    def add_headers(self, title, items):
        lines = []
        for key, value in items:
            if key.lower() in SENSITIVE_HEADERS:
                value = mask_secret(value)
            lines.append(f"{key}: {value}")
        self.add(title, "\n".join(lines))

    def flush(self):
        try:
            with open(self.path, "w", encoding="utf-8") as f:
                for title, body in self.sections:
                    f.write(f"{'=' * 70}\n{title}\n{'=' * 70}\n{body}\n\n")
        except Exception as e:
            print(f"[WARN] 写入抓包文件失败: {e}", flush=True)


class Decompressor:
    """增量解压器，用于在转发压缩响应的同时解析内容"""

    def __init__(self, content_encoding):
        encoding = (content_encoding or "").lower()
        self.supported = True
        self._obj = None

        if "gzip" in encoding:
            self._obj = zlib.decompressobj(16 + zlib.MAX_WBITS)
        elif "deflate" in encoding:
            self._obj = zlib.decompressobj()
        elif encoding and encoding != "identity":
            # br / zstd 等无法用标准库解压，放弃解析但仍正常转发
            self.supported = False

    def feed(self, chunk):
        """喂入原始字节，返回可解析的明文字节"""
        if not self.supported:
            return b""
        if self._obj is None:
            return chunk
        try:
            return self._obj.decompress(chunk)
        except zlib.error:
            self.supported = False
            return b""


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """处理每个请求在单独的线程中"""

    daemon_threads = True


class ProxyHandler(BaseHTTPRequestHandler):
    routes = {}
    stats_lock = threading.Lock()
    protocol_version = "HTTP/1.1"

    # 上一次写入所属的日期，用于检测跨天
    _current_day = None

    # ------------------------------------------------------------------ 日志

    def log_message(self, fmt, *args):
        """自定义日志格式"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        text = fmt % args if args else fmt
        print(f"[{timestamp}] {text}", flush=True)

    # ------------------------------------------------------------- 路由解析

    def resolve_route(self):
        """
        根据路径前缀确定 provider 与上游 URL。
        返回 (provider, upstream_url)。
        """
        path = self.path

        for prefix, domain in self.routes.items():
            if path == prefix or path.startswith(prefix + "/"):
                if not domain.startswith("http"):
                    domain = f"https://{domain}"
                stripped_path = path[len(prefix):]
                if not stripped_path.startswith("/"):
                    stripped_path = "/" + stripped_path
                provider = prefix.lstrip("/") or "default"
                return provider, f"{domain}{stripped_path}"

        # 未匹配任何前缀：退回 Host 头
        host = self.headers.get("Host", "")
        if ":" in host:
            host = host.split(":")[0]
        return "unknown", f"https://{host}{path}"

    @staticmethod
    def detect_api_format(path):
        """根据路径判断 API 协议格式：anthropic 或 openai"""
        lowered = path.lower()
        if "/messages" in lowered or "anthropic" in lowered:
            return "anthropic"
        return "openai"

    # --------------------------------------------------------- token 归一化

    @staticmethod
    def empty_tokens():
        return {
            "new_input_tokens": 0,
            "cached_tokens": 0,
            "cache_creation_tokens": 0,
            "output_tokens": 0,
        }

    @staticmethod
    def normalize_openai_usage(usage):
        """
        OpenAI 格式：prompt_tokens 已包含缓存命中部分，需要减出纯新增。
        兼容 DeepSeek 的 prompt_cache_hit_tokens 字段。
        """
        usage = usage or {}
        details = usage.get("prompt_tokens_details") or {}

        cached = details.get("cached_tokens")
        if cached is None:
            cached = usage.get("prompt_cache_hit_tokens")
        cached = cached or 0

        prompt_tokens = usage.get("prompt_tokens") or 0
        new_input = max(prompt_tokens - cached, 0)

        return {
            "new_input_tokens": new_input,
            "cached_tokens": cached,
            "cache_creation_tokens": 0,
            "output_tokens": usage.get("completion_tokens") or 0,
        }

    @staticmethod
    def normalize_anthropic_usage(usage):
        """Anthropic 格式：input_tokens 本身就不含缓存，无需相减。"""
        usage = usage or {}
        cache_creation = usage.get("cache_creation_input_tokens") or 0

        # 部分网关会把缓存写入拆成 5m / 1h 两档，取聚合值与拆分值的较大者，
        # 与 new-api cacheCreationTokensForOpenAIUsage() 的做法一致。
        creation_detail = usage.get("cache_creation") or {}
        split_total = (
            (creation_detail.get("ephemeral_5m_input_tokens") or 0)
            + (creation_detail.get("ephemeral_1h_input_tokens") or 0)
        )
        cache_creation = max(cache_creation, split_total)

        return {
            "new_input_tokens": usage.get("input_tokens") or 0,
            "cached_tokens": usage.get("cache_read_input_tokens") or 0,
            "cache_creation_tokens": cache_creation,
            "output_tokens": usage.get("output_tokens") or 0,
        }

    @staticmethod
    def detect_usage_semantic(usage):
        """
        仅凭 usage 字段本身判断语义，不依赖厂商名或模型名。
        对应 new-api 的 UsageSemantic（service/text_quota.go:302-311）。

        判断依据是"输入总量字段用的是哪个名字"，因为这唯一决定了要不要做减法：

            input_tokens   → anthropic 语义，该值不含缓存，直接用
            prompt_tokens  → openai 语义，该值已含缓存，需减去 cached

        ⚠️ 不能用缓存字段名来判断。实测阿里云的 message_delta 会同时出现
        两种风格的字段（cache_read_input_tokens 与 prompt_tokens_details 并存），
        只有输入总量字段是互斥的、可靠的。

        返回 "anthropic" / "openai" / None（无法判断）。
        """
        usage = usage or {}
        has_input = "input_tokens" in usage
        has_prompt = "prompt_tokens" in usage

        if has_input and not has_prompt:
            return "anthropic"
        if has_prompt and not has_input:
            return "openai"
        if has_input and has_prompt:
            # 两个都有：以数值更大者为总量口径（含缓存的那个必然 >= 不含的）
            return "openai" if (usage.get("prompt_tokens") or 0) > (usage.get("input_tokens") or 0) else "anthropic"
        return None

    @classmethod
    def normalize_usage(cls, usage, api_format=None):
        """
        把任意厂商的 usage 归一化。优先按字段判断语义，
        无法判断时才退回按 URL 路径推测的 api_format。
        """
        usage = usage or {}
        semantic = cls.detect_usage_semantic(usage) or api_format or "openai"
        if semantic == "anthropic":
            return cls.normalize_anthropic_usage(usage)
        return cls.normalize_openai_usage(usage)

    @classmethod
    def merge_tokens(cls, base, incoming, *, authoritative=False):
        """
        将 incoming 的 usage 合并进 base。

        各家厂商的两阶段 usage 行为差异很大（均为实测结果）：

            渠道        message_start        message_delta
            DeepSeek    input=20837          input=20837   （两边一致）
            MiniMax     input=0              input=280     （start 为空）
            阿里云      input=24681          input=6       （start 是粗估，delta 才真）

        可见 message_delta 才是权威的最终值，不能用 max() 取最大值——
        否则阿里云会永远取到那个虚高的预估值，使新增输入被大幅高估。

        authoritative=True 时直接覆盖（用于 message_delta）；
        authoritative=False 时只填补尚为 0 的字段（用于 message_start 的预估）。
        """
        for key in base:
            value = incoming.get(key)
            if value is None:
                # 厂商未返回该字段，保留已有值
                continue
            if authoritative or base[key] == 0:
                base[key] = value
        return base

    # ------------------------------------------------------------- 统计落盘

    def save_stats(self, stat):
        """按天追加统计记录，跨天时自动清理过期文件"""
        now = datetime.now()
        today = now.strftime("%Y-%m-%d")
        path = stats_file_for(now)

        try:
            with self.stats_lock:
                # 跨天（或进程内首次写入）时顺手清理旧文件
                if ProxyHandler._current_day != today:
                    ProxyHandler._current_day = today
                    for name in purge_old_stats():
                        print(f"[INFO] 已清理过期统计: {name}", flush=True)

                with open(path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(stat, ensure_ascii=False) + "\n")
        except Exception as e:
            self.log_message(f"写入统计失败: {e}")

    def record(self, *, provider, model, api_format, path, tokens,
               status_code, started_at, ttft, is_stream, error=None):
        """组装并保存一条统计记录"""
        tokens = tokens or self.empty_tokens()
        total_input = (
            tokens["new_input_tokens"]
            + tokens["cached_tokens"]
            + tokens["cache_creation_tokens"]
        )
        # 命中率分母 = 真实总输入（含缓存写入），详见文件头说明。
        # 落盘存一份，下游只需 Σcached / Σhit_rate_denominator 即可得到汇总命中率。
        hit_rate_denominator = total_input

        now = time.time()
        stat = {
            "timestamp": datetime.fromtimestamp(started_at).strftime("%Y-%m-%d %H:%M:%S"),
            "provider": provider,
            "model": model,
            "api_format": api_format,
            "path": path,
            "stream": is_stream,
            "status_code": status_code,
            "duration_ms": int((now - started_at) * 1000),
            "ttft_ms": int((ttft - started_at) * 1000) if ttft else None,
            "tokens": {
                **tokens,
                "total_input_tokens": total_input,
                "total_tokens": total_input + tokens["output_tokens"],
                "hit_rate_denominator": hit_rate_denominator,
            },
        }
        if error:
            stat["error"] = str(error)[:500]

        # model 解析不出来的记录一律不落盘。
        #
        # 主要针对探活请求：Claude Code 会打 /api/hello 这类探测端点，它没有 model、
        # 也不产生 token，落盘只会让界面上多出一行毫无信息量的 "unknown"。
        #
        # 判据**只看 model，不看 token**，这是有意的取舍：理论上"请求体畸形但确实
        # 消耗了 token"的调用也会被丢掉，总输入会少算一点。选这一边的理由是历史
        # 711 条里这种记录有 0 条，而多加一个 token 条件就意味着界面上永远还有
        # 冒出 unknown 的可能。宁可少算那种理论情况。
        #
        # 注意真实失败不会被误伤：429、上游超时这类零输出的失败，model 是从请求体里
        # 拿到的，不是 UNKNOWN_MODEL，照常落盘。
        #
        # 只跳过落盘，控制台那行照打（下面会标注"未计入统计"）：/api/hello 返回 401
        # 恰恰说明 key 有问题，这个信号不能丢，只是它不该进 token 统计。
        is_unknown = model == UNKNOWN_MODEL
        if not is_unknown:
            self.save_stats(stat)

        suffix = "（未计入统计）" if is_unknown else ""
        if error:
            self.log_message(f"✗ {provider}/{model} | {status_code} | {error}{suffix}")
        else:
            message = (
                f"✓ {provider}/{model} | 新增输入: {tokens['new_input_tokens']} | "
                f"输出: {tokens['output_tokens']} | 缓存读: {tokens['cached_tokens']}"
            )
            # 缓存写入是一次性开销且通常量很大，有值时必须显示，否则会漏掉成本大头
            if tokens["cache_creation_tokens"]:
                message += f" | 缓存写: {tokens['cache_creation_tokens']}"
            if hit_rate_denominator:
                rate = tokens["cached_tokens"] * 100.0 / hit_rate_denominator
                message += f" | 命中率: {rate:.0f}%"
            message += f" | 耗时: {stat['duration_ms']}ms"
            if stat["ttft_ms"] is not None:
                message += f" | 首字: {stat['ttft_ms']}ms"
            self.log_message(message + suffix)

    # --------------------------------------------------------------- 请求体

    def build_upstream_body(self, request_body, api_format):
        """
        OpenAI 格式的流式请求若未开启 include_usage，上游不会返回 usage。
        这里自动注入，保证 token 统计准确。
        返回 (body, model, is_stream)。
        """
        model = UNKNOWN_MODEL
        is_stream = False

        if not request_body:
            return request_body, model, is_stream

        try:
            payload = json.loads(request_body)
        except (ValueError, UnicodeDecodeError):
            return request_body, model, is_stream

        if not isinstance(payload, dict):
            return request_body, model, is_stream

        model = payload.get("model") or model
        is_stream = bool(payload.get("stream"))

        if is_stream and api_format == "openai":
            options = payload.get("stream_options")
            if not isinstance(options, dict):
                options = {}
            if not options.get("include_usage"):
                options["include_usage"] = True
                payload["stream_options"] = options
                request_body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

        return request_body, model, is_stream

    def build_upstream_headers(self, body_length):
        """构造转发给上游的请求头"""
        headers = {}
        for key, value in self.headers.items():
            lowered = key.lower()
            if lowered in HOP_BY_HOP_HEADERS:
                continue
            if lowered in ("host", "content-length", "accept-encoding"):
                continue
            headers[key] = value

        # 只声明标准库能解压的编码，避免 br / zstd 导致无法解析
        headers["Accept-Encoding"] = "gzip, deflate"
        if body_length:
            headers["Content-Length"] = str(body_length)
        return headers

    # --------------------------------------------------------------- 响应头

    def relay_headers(self, status_code, headers, *, chunked, content_length=None):
        """把上游响应头转发给客户端"""
        self.send_response_only(status_code)
        for key, value in headers:
            lowered = key.lower()
            if lowered in HOP_BY_HOP_HEADERS or lowered == "content-length":
                continue
            self.send_header(key, value)

        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif content_length is not None:
            self.send_header("Content-Length", str(content_length))
        self.end_headers()

    def write_chunk(self, data):
        """以 chunked 编码写出一段数据"""
        if not data:
            return
        self.wfile.write(f"{len(data):X}\r\n".encode("ascii"))
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def end_chunks(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    # ----------------------------------------------------------- 请求主流程

    def do_request(self, method):
        started_at = time.time()
        provider, upstream_url = self.resolve_route()
        api_format = self.detect_api_format(self.path)

        # 读取请求体
        try:
            content_length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            content_length = 0
        request_body = self.rfile.read(content_length) if content_length > 0 else b""

        original_body = request_body
        request_body, model, is_stream = self.build_upstream_body(request_body, api_format)

        self.log_message(
            f"→ {method} {provider} {self.path} | 模型: {model} | "
            f"格式: {api_format} | 流式: {is_stream}"
        )

        headers = self.build_upstream_headers(len(request_body))

        capture = None
        if CAPTURE_ENABLED:
            capture = Capture(provider, method, self.path)
            capture.add("上游 URL", upstream_url)
            capture.add(
                "识别结果",
                f"provider={provider}\napi_format={api_format}\n"
                f"model(请求)={model}\nstream(请求)={is_stream}",
            )
            capture.add_headers("客户端请求头", self.headers.items())
            capture.add_headers("转发给上游的请求头", headers.items())
            capture.add("客户端请求体", pretty_json(original_body))
            if request_body != original_body:
                capture.add("改写后的请求体（已注入 include_usage）", pretty_json(request_body))

        ssl_context = ssl.create_default_context()

        try:
            req = urllib.request.Request(
                upstream_url,
                data=request_body if method in ("POST", "PUT", "PATCH") else None,
                headers=headers,
                method=method,
            )

            with urllib.request.urlopen(req, context=ssl_context, timeout=UPSTREAM_TIMEOUT) as response:
                status_code = response.status
                response_headers = response.getheaders()
                content_type = (response.getheader("Content-Type") or "").lower()
                content_encoding = response.getheader("Content-Encoding")

                # 以响应的 Content-Type 为准判断是否为流式，比请求体更可靠
                streaming = "text/event-stream" in content_type

                if capture:
                    capture.add(
                        "上游响应状态",
                        f"status={status_code}\ncontent_type={content_type}\n"
                        f"content_encoding={content_encoding}\nstreaming={streaming}",
                    )
                    capture.add_headers("上游响应头", response_headers)

                if streaming:
                    self.relay_headers(status_code, response_headers, chunked=True)
                    self.handle_stream_response(
                        response,
                        provider=provider,
                        model=model,
                        api_format=api_format,
                        status_code=status_code,
                        started_at=started_at,
                        content_encoding=content_encoding,
                        capture=capture,
                    )
                else:
                    response_body = response.read()
                    self.relay_headers(
                        status_code,
                        response_headers,
                        chunked=False,
                        content_length=len(response_body),
                    )
                    self.wfile.write(response_body)
                    self.wfile.flush()

                    self.handle_plain_response(
                        response_body,
                        provider=provider,
                        model=model,
                        api_format=api_format,
                        status_code=status_code,
                        started_at=started_at,
                        content_encoding=content_encoding,
                        capture=capture,
                    )

        except urllib.error.HTTPError as e:
            error_body = e.read()
            self.relay_headers(
                e.code,
                list(e.headers.items()),
                chunked=False,
                content_length=len(error_body),
            )
            # 转发给客户端的必须是原始字节（Content-Encoding 头也照原样转发），
            # 解压只作用于下面记日志用的那份副本
            self.wfile.write(error_body)
            self.wfile.flush()

            decoded_body = decode_for_log(error_body, e.headers.get("Content-Encoding"))
            detail = decoded_body.decode("utf-8", errors="replace")[:500]
            if capture:
                capture.add("上游错误响应", f"status={e.code}\n\n{pretty_json(decoded_body)}")
                capture.flush()

            self.record(
                provider=provider,
                model=model,
                api_format=api_format,
                path=self.path,
                tokens=None,
                status_code=e.code,
                started_at=started_at,
                ttft=None,
                is_stream=is_stream,
                error=detail or f"HTTP {e.code}",
            )

        except (BrokenPipeError, ConnectionResetError):
            self.log_message("客户端提前断开连接")
            if capture:
                capture.add("异常", "客户端提前断开连接")
                capture.flush()

        except Exception as e:
            self.log_message(f"请求失败: {e}")
            try:
                message = f"Proxy Error: {e}".encode("utf-8")
                self.relay_headers(
                    502,
                    [("Content-Type", "text/plain; charset=utf-8")],
                    chunked=False,
                    content_length=len(message),
                )
                self.wfile.write(message)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

            if capture:
                capture.add("异常", repr(e))
                capture.flush()

            self.record(
                provider=provider,
                model=model,
                api_format=api_format,
                path=self.path,
                tokens=None,
                status_code=502,
                started_at=started_at,
                ttft=None,
                is_stream=is_stream,
                error=e,
            )

    # ------------------------------------------------------- 非流式响应解析

    def handle_plain_response(self, response_body, *, provider, model, api_format,
                              status_code, started_at, content_encoding, capture=None):
        """解析非流式响应并保存统计信息"""
        tokens = self.empty_tokens()
        error = None

        try:
            body = response_body
            encoding = (content_encoding or "").lower()
            if "gzip" in encoding:
                body = gzip.decompress(body)
            elif "deflate" in encoding:
                body = zlib.decompress(body)
            elif encoding and encoding != "identity":
                raise ValueError(f"不支持的 Content-Encoding: {encoding}")

            if capture:
                capture.add("上游响应体（已解压）", pretty_json(body))

            payload = json.loads(body)
            usage = payload.get("usage")

            if capture:
                capture.add("原始 usage 字段", json.dumps(usage, ensure_ascii=False, indent=2))

            tokens = self.normalize_usage(usage, api_format)

            # 响应里的 model 通常比请求里的更准确
            model = payload.get("model") or model

        except Exception as e:
            error = f"解析响应失败: {e}"
            if capture:
                capture.add("解析异常", repr(e))

        if capture:
            capture.add(
                "归一化后的 tokens",
                json.dumps(tokens, ensure_ascii=False, indent=2),
            )
            capture.flush()

        # 无论解析成功与否都落盘，保证请求数统计准确
        self.record(
            provider=provider,
            model=model,
            api_format=api_format,
            path=self.path,
            tokens=tokens,
            status_code=status_code,
            started_at=started_at,
            ttft=None,
            is_stream=False,
            error=error,
        )

    # --------------------------------------------------------- 流式响应解析

    def handle_stream_response(self, response, *, provider, model, api_format,
                               status_code, started_at, content_encoding, capture=None):
        """边转发边解析 SSE 流式响应"""
        tokens = self.empty_tokens()
        decompressor = Decompressor(content_encoding)
        ttft = None
        buffer = b""
        error = None
        resolved_model = model
        raw_sse = [] if capture else None
        usage_events = [] if capture else None
        # 与 usage_events 不同，这个列表在非抓包模式下也要收集：
        # 它是判定这条请求成功还是失败的依据，不是排查用的额外信息。
        stream_errors = []
        client_gone = False

        # read1() 返回当前已到达的数据，不会阻塞等待凑满缓冲区；
        # 用 read() 会一直等到读满 n 字节，SSE 场景下会导致明显卡顿。
        reader = getattr(response, "read1", None) or response.read

        try:
            while True:
                chunk = reader(65536)
                if not chunk:
                    break

                # 先转发，保证流式体验
                try:
                    self.write_chunk(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    # 标记连接已断，后面不能再写 end_chunks，否则又会抛
                    # BrokenPipeError 并被记成"处理流式响应失败"，掩盖真实原因
                    client_gone = True
                    self.log_message("客户端断开连接，停止转发")
                    break

                if ttft is None:
                    ttft = time.time()

                # 再解析
                plain = decompressor.feed(chunk)
                if raw_sse is not None and plain:
                    raw_sse.append(plain)
                buffer += plain
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    found = self.parse_sse_line(
                        line.decode("utf-8", errors="ignore"),
                        tokens,
                        api_format,
                        usage_events=usage_events,
                        stream_errors=stream_errors,
                    )
                    if found:
                        resolved_model = found

            if buffer:
                found = self.parse_sse_line(
                    buffer.decode("utf-8", errors="ignore"),
                    tokens,
                    api_format,
                    usage_events=usage_events,
                    stream_errors=stream_errors,
                )
                if found:
                    resolved_model = found

            if client_gone:
                error = "客户端提前断开"
            else:
                self.end_chunks()

            if not decompressor.supported:
                error = f"无法解析的 Content-Encoding: {content_encoding}"

            # 放在最后：上游自己报的错优先级最高。
            # 上面两种是代理侧/客户端侧的现象，这条是根因，也是唯一能解释
            # "status=200 却零输出"的信息——没有它这条会落盘成一次干净的成功。
            if stream_errors:
                error = "上游流内错误: " + " | ".join(stream_errors)

        except (BrokenPipeError, ConnectionResetError):
            error = "客户端提前断开"
            self.log_message(error)

        except Exception as e:
            error = f"处理流式响应失败: {e}"
            self.log_message(error)

        if capture:
            stream_text = b"".join(raw_sse).decode("utf-8", errors="replace")
            capture.add("完整原始 SSE 流（已解压）", stream_text)
            capture.add(
                "含 usage 的事件（按到达顺序）",
                "\n\n".join(usage_events) if usage_events else "（未发现任何 usage 字段）",
            )
            capture.add("归一化后的 tokens", json.dumps(tokens, ensure_ascii=False, indent=2))
            if error:
                capture.add("解析异常", error)
            capture.flush()

        self.record(
            provider=provider,
            model=resolved_model,
            api_format=api_format,
            path=self.path,
            tokens=tokens,
            status_code=status_code,
            started_at=started_at,
            ttft=ttft,
            is_stream=True,
            error=error,
        )

    def parse_sse_line(self, line, tokens, api_format, usage_events=None,
                       stream_errors=None):
        """
        解析单行 SSE 数据，把 usage 合并进 tokens。
        返回响应中声明的 model 名（若有）。

        流内错误通过 stream_errors 这个可变列表带出去，而不是改返回值——
        返回值的语义是 model 名，两个调用点都按 `if found: resolved_model = found` 用它。
        """
        line = line.strip()
        if not line.startswith("data:"):
            return None

        data = line[5:].strip()
        if not data or data == "[DONE]":
            return None

        try:
            event = json.loads(data)
        except ValueError:
            return None
        if not isinstance(event, dict):
            return None

        event_type = event.get("type") or ""
        model = event.get("model")

        # 错误检查独立于下面那条 usage 的 if/elif 链：有网关会在报错的同一个事件里
        # 带上已消耗的 usage，两样都得收。去重是防止上游反复推同一条错误把字段撑爆。
        stream_error = extract_stream_error(event)
        if stream_error and stream_errors is not None and stream_error not in stream_errors:
            stream_errors.append(stream_error)

        # Anthropic: message_start 的 usage 只是预估，仅用于填补尚为 0 的字段
        if event_type == "message_start":
            message = event.get("message") or {}
            model = message.get("model") or model
            usage = message.get("usage")
            if usage:
                self.merge_tokens(tokens, self.normalize_usage(usage, api_format))
                if usage_events is not None:
                    usage_events.append(
                        f"[message_start] {json.dumps(usage, ensure_ascii=False)}"
                    )

        # Anthropic: message_delta 是权威的最终值，直接覆盖
        elif event_type == "message_delta":
            usage = event.get("usage")
            if usage:
                self.merge_tokens(
                    tokens,
                    self.normalize_usage(usage, api_format),
                    authoritative=True,
                )
                if usage_events is not None:
                    usage_events.append(
                        f"[message_delta] {json.dumps(usage, ensure_ascii=False)}"
                    )

        # OpenAI: 最后一个 chunk 的 usage 字段（前面的 chunk 是 null），同样是权威终值
        elif event.get("usage"):
            usage = event["usage"]
            self.merge_tokens(
                tokens, self.normalize_usage(usage, api_format), authoritative=True
            )
            if usage_events is not None:
                usage_events.append(
                    f"[chunk usage] {json.dumps(usage, ensure_ascii=False)}"
                )

        return model

    # ------------------------------------------------------------ HTTP 方法

    def do_GET(self):
        self.do_request("GET")

    def do_POST(self):
        self.do_request("POST")

    def do_PUT(self):
        self.do_request("PUT")

    def do_DELETE(self):
        self.do_request("DELETE")

    def do_PATCH(self):
        self.do_request("PATCH")

    def do_HEAD(self):
        # 健康检查/探活常用 HEAD。不实现会返回 501，且该请求不会被统计。
        self.do_request("HEAD")


def main():
    setup_logging()

    print("=" * 64)
    print(f"[INFO] TokenScope 代理启动 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    ProxyHandler.routes = load_routes()
    print(f"[INFO] 已加载 {len(ProxyHandler.routes)} 个路由规则")
    for prefix, domain in ProxyHandler.routes.items():
        print(f"       {prefix:12s} → {domain}")

    # 启动时先清一次过期文件
    for name in purge_old_stats():
        print(f"[INFO] 已清理过期统计: {name}")

    httpd = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)

    print(f"[INFO] HTTP 反向代理已启动: http://{LISTEN_HOST}:{LISTEN_PORT}")
    print(f"[INFO] 统计数据写入: {stats_file_for(datetime.now())}")
    if RETENTION_DAYS > 0:
        print(f"[INFO] 统计保留 {RETENTION_DAYS} 天（AI_PROXY_RETENTION_DAYS 可调，0 为不清理）")
    else:
        print("[INFO] 统计文件永久保留")
    print(
        f"[INFO] 日志: {LOG_FILE}"
        f"（单文件上限 {LOG_MAX_BYTES // 1024 // 1024}MB，保留 {LOG_BACKUP_COUNT} 个历史文件）"
    )
    if CAPTURE_ENABLED:
        print(f"[INFO] 抓包模式已开启，完整报文写入: {CAPTURE_DIR}/")
        print("[INFO] 敏感请求头（Authorization / x-api-key 等）会自动脱敏")
    else:
        print("[INFO] 抓包模式未开启（设置 AI_PROXY_CAPTURE=1 可记录完整报文）")
    print("[INFO] 按 Ctrl+C 停止")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[INFO] 正在关闭...")
        httpd.shutdown()


if __name__ == "__main__":
    main()
