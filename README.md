# TokenScope

本地 LLM API 反向代理 + macOS 菜单栏统计工具。

把客户端（Claude Code、Cursor 等）的 base URL 指向本地代理，即可拦截并统计各渠道的
token 消耗、缓存命中率与响应延迟，无需安装任何证书。

```
客户端 ──> proxy (:12345) ──> 各厂商 API
                │
                ├─> ai_stats-YYYY-MM-DD.jsonl
                │
                └─> TokenScope.app（菜单栏实时展示）
```

## 目录结构

```
proxy/                    Python 反向代理
  http_proxy.py           主程序：转发 + usage 解析 + 落盘
  ai_stats_domains.json   路由配置（路径前缀 → 上游域名；聚合路由规则）
  ai_keys.json            聚合路由用的各渠道 API key（不入库）
  stats_report.py         命令行报表工具
  selftest_usage.py       归一化 / 路由回归自测
app/                      SwiftUI 菜单栏应用
  Sources/TokenScope/     源码
  icon/                   图标与生成脚本
  build.sh                编译 + 打包 + 签名
```

## 快速开始

### 1. 配置路由

复制示例文件，填入你自己的上游域名：

```bash
cd proxy
cp ai_stats_domains.example.json ai_stats_domains.json
```

编辑 `ai_stats_domains.json`，把路径前缀映射到上游域名：

```json
{
    "routes": {
        "/deepseek": "api.deepseek.com",
        "/minimax": "api.minimaxi.com",
        "/anthropic": "api.anthropic.com"
    }
}
```

> `ai_stats_domains.json` 已在 `.gitignore` 中 —— 它可能含内网或私有网关地址，
> 不应入库。只有 `.example.json` 会被提交。

### 2. 启动代理

```bash
cd proxy
python3 http_proxy.py
```

### 3. 修改客户端配置

把 base URL 的域名部分换成 `127.0.0.1:12345/<前缀>`，路径保持不变：

| 原地址                                    | 改为                                             |
| ----------------------------------------- | ------------------------------------------------ |
| `https://api.deepseek.com/v1`           | `http://127.0.0.1:12345/deepseek/v1`           |
| `https://api.deepseek.com/anthropic/v1` | `http://127.0.0.1:12345/deepseek/anthropic/v1` |

> ⚠️ 必须用 `http://` 而非 `https://`。代理是纯 HTTP 服务，
> 用 https 连接会导致 TLS 握手包被当作 HTTP 请求解析而报错。

### 4. 构建并启动菜单栏应用

```bash
cd app
./build.sh run
```

图标出现在菜单栏右上角（⚡），点击查看统计。

## 聚合路由（按模型自动转发）

上面那套是**路径前缀路由**：一个渠道一个 base URL，key 由客户端带、代理只透传。
想在多个渠道间切模型就得来回改客户端配置。

聚合路由把这件事挪到代理侧：客户端只填**一个** base URL 和一个占位 key，
代理按请求体里的 `model` 决定转发到哪个上游、注入哪个 key。

### 1. 配好上游与模型规则

在 `ai_stats_domains.json` 里加 `aggregate` 段（完整带注释的示例见
`ai_stats_domains.example.json`）：

```json
{
    "routes": { "...": "原有前缀路由，保持不动" },
    "aggregate": {
        "prefix": "/auto",
        "targets": {
            "deepseek": {
                "openai": "https://api.deepseek.com",
                "anthropic": "https://api.deepseek.com/anthropic"
            },
            "minimax": {
                "openai": "https://api.minimaxi.com",
                "anthropic": "https://api.minimaxi.com/anthropic"
            }
        },
        "models": {
            "deepseek-*": "deepseek",
            "MiniMax-*": "minimax"
        },
        "default": "deepseek"
    }
}
```

`targets` 里的 base **要带上该渠道私有的路径前缀**。转发时直接拼接
`base + 客户端剥掉 /auto 后的原路径`，query string 一并保留：

| 客户端请求                       | target base                            | 实际转发到                                             |
| -------------------------------- | -------------------------------------- | ------------------------------------------------------ |
| `/auto/v1/messages?beta=true`  | `https://api.deepseek.com/anthropic` | `https://api.deepseek.com/anthropic/v1/messages?beta=true` |
| `/auto/v1/chat/completions`    | `https://api.deepseek.com`           | `https://api.deepseek.com/v1/chat/completions`       |

`openai` 这一项同时服务 `/v1/chat/completions` 与 `/v1/responses`。
只配了 `anthropic` 的 target 收到 OpenAI 协议请求会返回 400，反之同理。

`models` 支持 `*` `?` `[]` 通配（fnmatch 语法，**大小写敏感**）。
匹配顺序是**先精确、再按书写顺序通配**，所以把具体模型名写在通配规则前面就能做特例。

### 2. 填 key

```bash
cd proxy
cp ai_keys.example.json ai_keys.json
chmod 600 ai_keys.json          # 明文密钥，收紧权限
```

键名与 `aggregate.targets` 的 target 名一致。代理会按协议自动选注入方式：
anthropic 用 `x-api-key`（并在缺失时补 `anthropic-version`），openai 用
`Authorization: Bearer`。**客户端自己带的凭证会先被剔除**，避免上游同时收到两套。

> `ai_keys.json` 已在 `.gitignore` 中。启动时若发现它同组/其他用户可读，会打一条 WARN。

### 3. 客户端只填一个地址

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:12345/auto
ANTHROPIC_AUTH_TOKEN=placeholder        # 占位即可，会被代理替换
```

### 与前缀路由的关系

- **前缀优先**：`routes` 先匹配，命中就原样透传（`auth=None`），行为与加聚合前逐字相同。
  聚合出问题时把 base URL 改回带前缀的写法即可立即回退。
- 落盘的 `provider` 记的是**真实 target 名**（`deepseek` / `minimax`…），不是 `auto`。
  所以菜单栏应用与 `stats_report.py` 无需改动，聚合流量还会和走老前缀的同渠道流量合并到一行。
- 整段删掉 `aggregate` 即关闭该特性。
- 配置不全（模型没匹配上、target 缺端点、缺 key）时返回 **400 并在 body 里说明缺什么**，
  不会把请求转发到一个猜出来的地址 —— 那样客户端只会看到一个和真实原因无关的上游报错。
  这类失败只打日志、不落盘（属代理配置错误，不是真实 API 消耗）。

## 统计口径

各厂商返回的 usage 字段语义不一致，代理会先做归一化再落盘。
判断依据**只看输入总量字段名**，与厂商、模型无关：

| 上游字段                                | 语义                                     | 换算                                                  |
| --------------------------------------- | ---------------------------------------- | ----------------------------------------------------- |
| `input_tokens`                        | 不含缓存（Anthropic 风格）               | `new_input = input_tokens`                          |
| `prompt_tokens`                       | 已含缓存（OpenAI Chat Completions 风格） | `new_input = prompt_tokens - cached`                |
| `input_tokens` + `input_tokens_details` | 已含缓存**读和写**（OpenAI Responses 风格） | `new_input = input_tokens - cached - cache_write` |

> ⚠️ 第三行是唯一的例外，也是最容易算错的一处：**Responses API 的字段名叫
> `input_tokens`（和 Anthropic 一样），但语义是 OpenAI 的**。照 Anthropic 那样直接
> 取用，缓存部分会被算进新增输入（成本虚高），而 `cache_read_input_tokens` 又取不到
> → 命中率恒为 0%。
>
> 判据用的是 `input_tokens_details` 这个**容器名**。它与 Chat Completions 的
> `prompt_tokens_details` 是两个不同的键，所以并不违反「不能用缓存字段名判断」那条
> —— 那条说的是 `cached_tokens` 这类叶子字段会跨风格并存，容器名不会。
>
> 而且要减**两项**（读 + 写），不是只减 `cached`。这一点与 cc-switch 一致
> （`src-tauri/src/proxy/usage/calculator.rs` 的 `calculate_with_cache_semantics()`）；
> 那边还留着 `INPUT_TOKEN_SEMANTICS_LEGACY / TOTAL / FRESH` 三态常量 —— 早期只减了
> `cache_read`，是后来发现漏减 `cache_write` 才补的迁移。
>
> 减完后 `new_input + cached + cache_creation` 恰好等于上游报的 `input_tokens`，
> 命中率分母仍是「上游声称的总输入」，与本项目既有口径自洽。

Responses API 另有两处与 Chat Completions 不同，都已处理：

- **流式 usage 嵌在事件的 `response` 对象里**，不在事件顶层
  （`{"type":"response.completed","response":{...,"usage":{...}}}`）。
  只看顶层会让每条流式请求静默记成 0 token。
- **不能注入 `stream_options.include_usage`**。Responses 版 `stream_options` 只有
  `include_obfuscation` 这一个键，塞 `include_usage` 是非法嵌套参数、上游直接 400。
  它本来也不需要 —— 终值事件无条件带 usage。

落盘后的字段：

| 字段                      | 含义                         |
| ------------------------- | ---------------------------- |
| `new_input_tokens`      | 纯新增输入，不含缓存         |
| `cached_tokens`         | 缓存读取（命中）             |
| `cache_creation_tokens` | 缓存写入（一次性建缓存开销） |
| `output_tokens`         | 输出（含 reasoning）         |

### 缓存命中率

```
命中率 = Σ cached_tokens / Σ total_input_tokens
       = Σ cached / Σ (new_input + cached + cache_creation)
```

三个要点：

- **分母包含 `cache_creation_tokens`** —— 回答的是"全部输入里有多少靠缓存复用"
- **分母不含 `output_tokens`** —— 缓存只作用于输入，输出永远不可能命中
- **必须先汇总再相除**，不能每条请求各算一次再取平均，否则一条小请求会和一条
  十万 token 的请求权重相同

> ⚠️ 此口径与 new-api **不同**。new-api 的分母只含 `new_input + cached`
> （见 `ChannelAffinityUsageCacheModal.jsx:41-51`），回答的是"本可命中的部分命中了多少"，
> 同一份数据下会得出高得多的数字（实测 98% vs 65%）。
>
> 两者都不算错，只是问的问题不同：new-api 衡量**缓存机制效率**，
> 本项目衡量**总输入的缓存复用程度**（建缓存的开销也计入分母）。
>
> 副作用：首次建缓存的请求（`cache_creation` 很大而 `cached` 为 0）命中率会是 0%，
> 即便那次建缓存完全正确。这是本口径的固有特性。

### 成本构成

缓存命中率反映不了成本，因为各项 token 的计费倍率差异很大。
界面上的"计费等效"按 new-api 默认倍率折算：

| 项目     | 倍率                            |
| -------- | ------------------------------- |
| 新增输入 | 1.0                             |
| 缓存读取 | 0.1                             |
| 缓存写入 | **1.25**（5m）/ 2.0（1h） |
| 输出     | 1.0                             |

### 流式 usage 的合并规则

Anthropic 协议的 usage 分两个事件下发，各家行为差异很大（实测）：

| 行为                        | `message_start`       | `message_delta`   |
| --------------------------- | ----------------------- | ------------------- |
| 两边一致                    | `input=20837`         | `input=20837`     |
| `start` 为空              | `input=0`             | `input=280`       |
| `start` 粗估、`delta` 真 | `input=24681`         | `input=6`         |

因此 **`message_delta` 是权威终值，直接覆盖**；`message_start` 只用于填补尚为 0 的字段。

> ⚠️ **不能取最大值。** 碰上第三种行为时，`max()` 会永远取到那个虚高的预估值，
> 新增输入被高估上万、命中率被严重低估。三种都是真实抓包结果，第三种别当成理论情况。

## 环境变量

| 变量                        | 默认  | 说明                                                                |
| --------------------------- | ----- | ------------------------------------------------------------------- |
| `AI_PROXY_RETENTION_DAYS` | `3` | 统计文件保留天数，`0` 为永久保留                                  |
| `AI_PROXY_CAPTURE`        | 关闭  | 设为`1` 记录完整报文到 `proxy/captures/`，用于排查 token 对不上 |
| `TOKENSCOPE_STATS_DIR`    | 自动  | 覆盖统计文件目录，默认从 app 位置推算仓库内的`proxy/`             |

抓包模式下 `Authorization`、`x-api-key` 等敏感头会自动脱敏，
但**对话内容是明文**，`captures/` 已在 `.gitignore` 中。

## 命令行报表

```bash
cd proxy
python3 stats_report.py              # 今天
python3 stats_report.py 2026-07-29   # 指定日期
python3 stats_report.py --all        # 全部历史
```

输出总览、按渠道、按模型、按渠道+协议四张表，含命中率与延迟分位数。
可用于校验菜单栏应用的数值是否一致。

## 回归自测

```bash
cd proxy
python3 selftest_usage.py
```

纯 stdlib `assert`，不引依赖、不需要测试框架。把上面「统计口径」里每条结论都钉成断言：
三种风格的归一化、两种缓存字段并存的混合形态、`message_delta` 权威覆盖、
Responses 的嵌套 usage 与嵌套 error、聚合路由的 URL 拼接与密钥注入。

改归一化或路由逻辑前后都跑一下。这些数字错了不会报错也不会崩，只会让界面上的值
静静地偏掉几万 —— 肉眼发现不了。

## 数据文件

- 按天生成 `proxy/ai_stats-YYYY-MM-DD.jsonl`，每行一条 JSON
- **写入方只有代理**，应用只读，避免两个进程互相干扰
- 应用按文件名读取当天数据，跨天自动切换（不做时间戳过滤）
- 过期文件由代理在启动时和跨天时自动清理
