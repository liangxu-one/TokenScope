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
  balance.py              查询各渠道剩余额度
  selftest_usage.py       归一化 / 路由 / 额度解析回归自测
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

窗口默认**跟随系统外观**，也可以在底栏那个图标里单独固定成浅色或深色 ——
系统是浅色时窗口也能保持深色，反之亦然。选择存在 UserDefaults 里，重启后保留：

```bash
# 前面那串是 app 的 bundle id，写死在 app/build.sh 里（不随当前用户名变），
# 所以谁 build 出来都是这个，这行命令可以原样照抄。
defaults write io.github.liangxu-one.tokenscope appearancePreference dark   # system | light | dark
```

> 实现上是**直接给宿主 `NSWindow` 设 `NSAppearance`**（借一个空 `NSView` 拿到
> `view.window`）。两条看起来更自然的路都不行：
>
> - `preferredColorScheme` 是靠 preference 往上冒泡、由**场景**消费的，而
>   `MenuBarExtra(.window)` 的弹窗不是常规场景，**不吃这个 preference**。
>   症状很有误导性：偏好存下来了、底栏图标也变了，窗口纹丝不动。
>   用普通 `NSWindow` + `NSHostingView` 写的测试**会通过**（那条路径确实消费
>   preference），别被它骗了 —— 要验就得在真的 `MenuBarExtra` 里验。
> - `NSApp.appearance` 是应用级全局，会把菜单栏上那个图标一并拽进指定外观，
>   而菜单栏自身跟随系统，图标就和它所在的背景不搭。

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
| `TOKENSCOPE_PYTHON`       | 自动  | 覆盖菜单栏应用查额度时用的 python3，默认按固定顺序找，见「菜单栏里的余额区」 |

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

## 查询剩余额度

```bash
cd proxy
python3 balance.py               # 表格
python3 balance.py --line        # 单行摘要
python3 balance.py --json        # 机器可读
python3 balance.py --providers   # 列出内置提供方
python3 balance.py --min 5       # 货币余额低于 5 则退出码 1，挂 cron 做告警
```

```
============================================================
渠道剩余额度　2026-08-02 16:24:35
============================================================
  渠道        额度                        重置
  ────────────────────────────────────────────────────────
  deepseek    ¥10.73                      —
  minimax     5 小时 已用 1%              2026-08-02 20:00
              7 天   已用 23%             2026-08-03 00:00
```

`stats_report.py --balance` 会在表头带一行摘要。**不带这个参数就不联网** ——
报表本体只读本地 jsonl，离线可用、瞬间出结果，不该因为多一行额度就每次都等网络。

菜单栏应用里也有，见下面「菜单栏里的余额区」。

### 两种额度语义，不能混为一谈

各家的「剩余额度」不是同一种东西，归一化成两个 `kind`：

| kind         | 含义                                                                       | 例                              |
| ------------ | -------------------------------------------------------------------------- | ------------------------------- |
| `currency` | 货币余额。有金额与币种，随消耗单调减少，**只有充值才回升**，没有重置时间 | DeepSeek `¥10.73`             |
| `quota`    | 套餐额度。只有**已用百分比**与时间窗口，到点自动重置，**没有面值**      | MiniMax `5 小时 1% / 7 天 23%` |

> ⚠️ 别把 `quota` 折算成金额，也别给 `currency` 编一个百分比 —— 前者没有面值，
> 后者没有分母。展示侧必须按 `kind` 分别渲染。

两处都只存**一个方向的一份数据**，不存能互相推出来的第二份 —— 两份迟早漂移：

- `quota` 只存 `used_percent`，不存剩余量。要剩余量由展示侧算 `100 - used_percent`
- `currency` 只存 `total`，不存赠金/充值的拆分。DeepSeek 会返回
  `granted_balance` 与 `topped_up_balance`，但二者之和恒等于 `total_balance`，
  是同一笔钱的两种切法；而「赠金快到期了」这种真值得提醒的信息接口里并没给
  （没有到期时间），拆开也不可行动

### 查哪些渠道

从 `ai_stats_domains.json` 里**已配置**的渠道来（`routes` 与 `aggregate.targets`
都算），按上游域名匹配内置提供方：

| 情况                                   | 行为                               |
| -------------------------------------- | ---------------------------------- |
| 域名匹配到 + `ai_keys.json` 里有 key | 查询并展示                         |
| 域名匹配到但缺 key                     | 展示一行提示（这是可修的配置问题） |
| 域名没匹配到                           | **完全不显示**，不打扰             |

只用路径前缀、没配聚合路由的用户也能查 —— 把 key 加进 `ai_keys.json` 即可，
键名与前缀同名（`/deepseek` → `deepseek`）。

请求**直连上游**，不走本地代理 —— 这不是 LLM 调用，走代理只会往 jsonl 里塞
无意义的记录。

### 内置只有 DeepSeek 与 MiniMax

刻意只内置这两家：它们是本仓库**实测验证过**的，且正好各代表一种 `kind`，
可以直接当模板照抄。

各家余额接口的字段语义差异极大，凭文档照抄而不实测很容易写出「看起来有数字但
其实错了」的解析 —— 那比没有这个功能更糟。已经踩到的几个坑：

- DeepSeek 的 `total_balance` 是**字符串** `"10.73"` 而不是数字。当数字取会得到
  `None`、余额显示成 0，界面上完全看不出来
- MiniMax 的 `model_remains` 里混着 `video` 条目（百分比恒 100），只能取 `general`
- MiniMax 给的是**剩余**百分比，本模块统一存**已用**，要反转。方向搞反不会报错，
  只会把「已用 1%」显示成「已用 99%」
- MiniMax 第二个窗口要看 `current_weekly_status == 1` 才算激活，否则是假的 0%
- MiniMax 有业务级错误码，**HTTP 200 也可能是失败**，必须单独查 `base_resp`

这些结论都钉进了 `selftest_usage.py` 的断言。

### 自己加一家

写一个函数 + 一行装饰器即可，不用改其他任何地方：

```python
# proxy/balance.py

@provider("myvendor", "api.myvendor.com")      # 完整主机名，可写多个
def query_myvendor(api_key, base_url):
    payload, error = fetch("https://api.myvendor.com/v1/balance", api_key)
    return error or parse_myvendor(payload)

def parse_myvendor(payload):                    # 与网络分离，便于不联网单测
    return currency([{
        "currency": "CNY",
        "total": parse_number(payload, "balance"),   # 务必用 parse_number
    }])
```

可用的工具与构造器：

| 名称                                   | 用途                                                              |
| -------------------------------------- | ----------------------------------------------------------------- |
| `fetch(url, key, bearer=True)`       | GET JSON。`bearer=False` 时不加 `Bearer ` 前缀（有厂商这么要求） |
| `parse_number(obj, field)`           | 取数值，**兼容字符串写法**                                        |
| `millis_to_local(ms)`                | 毫秒时间戳 → 本地时间字符串                                       |
| `host_of(url)`                       | 取主机名。**要判断上游是哪个站点就用它**，别在原始 URL 上做子串匹配 |
| `currency(balances, available=True)` | 构造货币余额结果                                                  |
| `quota(windows)`                     | 构造套餐额度结果（存**已用**百分比）                              |
| `failure(msg, transient=False)`      | 构造失败。`transient=True` 表示网络类瞬时失败、值得重试           |

建议把解析拆成独立函数（像上面 `parse_myvendor` 那样），这样能不联网写单测 ——
字段语义的坑基本都只有测试能挡住。

> ⚠️ 传进来的 `base_url` 来自用户的配置文件，**不要拿它去 `in` 判断站点**。
> `find_provider` 用的是解析出来的主机名，因为下面三种都能骗过子串匹配：
> `api.deepseek.com.evil.example`（后缀冒充）、
> `api.deepseek.com@evil.example`（userinfo 冒充，真实主机是 `@` 之后那段）、
> `evil.example/?upstream=api.deepseek.com`（塞在 query 里）。
>
> 内置两家的额度 URL 是写死的，判错只是显示不对；但你的实现若按 `base_url`
> 拼请求地址，判错就等于把 key 发到配置里写的任意主机上。要判站点用 `host_of`。
> 这三种形状都钉在 `selftest_usage.py` 里了。
>
> 一个渠道配了多个端点（openai + anthropic）时，`base_url` 拿到的是**第一个**，
> 是个可直接用的完整地址，不是把多个拼起来的字符串。

其他厂商的端点与字段可参考 [cc-switch](https://github.com/farion1231/cc-switch)，
它覆盖面广得多：

- `src-tauri/src/services/balance.rs` —— 货币余额：StepFun、SiliconFlow、
  OpenRouter、Novita AI 等
- `src-tauri/src/services/coding_plan.rs` —— 套餐额度：Kimi、智谱、ZenMux 等

> 火山方舟不能照抄：它走控制面 OpenAPI（`open.volcengineapi.com`，不是数据面
> 推理域名）且强制火山签名 V4，凭据是 **AK/SK 一对**而不是单个 key，
> 与这里的凭据模型不兼容。

### 菜单栏里的余额区

在「缓存命中率」和「渠道 / 模型」明细表之间，每个渠道一行：

```
──────────────────────────────────────────────────────────────────
 ⊞ 剩余额度                                            18:17  ↻
 deepseek     ¥11.73
 minimax      5 小时 已用 1% ▁ ⏱08-02 20:00  7 天 已用 23% ▃ ⏱08-03 00:00
──────────────────────────────────────────────────────────────────
```

自带**抓取时间与刷新按钮**，不复用底部那个「更新于」：统计是读本地 jsonl、
30 秒一次；额度要联网打各厂商接口、5 分钟一次。共用一个时间戳会让人以为
余额也是 30 秒前的。

几个刻意的取舍：

| 现象                             | 原因                                                                     |
| -------------------------------- | ------------------------------------------------------------------------ |
| 只有套餐额度有进度条             | 货币余额**没有分母**，不知道"满"是多少。那类行右边是空的，不是漏画了     |
| 金额不按阈值变色                 | 多少算"低"取决于你的消耗速度，编一个阈值只会误导。唯一变红的依据是上游自己标记余额不足 |
| 已用百分比的配色与命中率**相反** | 命中率越高越好（绿），已用越高越糟（红）。两者都是 0~100 的比率，混用编译器不会报错，只会把颜色配反 |
| 重置时刻一律带日期、但不带年份   | `08-02 20:00`。不做「今天就省掉日期」的优化：那样两个窗口一个带日期一个不带、看着像没对齐，而且要判断「是不是今天」就得引入当前时间、时区和跨年这几类会算错的东西。年份省掉是因为窗口最长 7 天，`01-01` 只可能是明年元旦；带上年份两个窗口并排放不下（最坏情况右边只剩 13pt） |
| 货币余额那行右边是空的           | 没有重置周期可显示 —— 钱只能靠充值回升，不会到点自己回来                 |
| 超过 4 个渠道才出现滚动          | 上限 76pt。绝大多数人遇不到                                              |

取数是**跑 `python3 balance.py --json` 子进程**，不在 Swift 里重写各家接口。
这样上面「自己加一家」那套对菜单栏同样生效 —— 谁给 `balance.py` 加了渠道，
菜单栏立刻就能显示，不用再写一遍 Swift。反之若两边各有一份实现，那 5 个字段
陷阱就会在两种语言里各存一份，而且**算错不会报错**，只会静静显示一个错数字。

解释器按 `TOKENSCOPE_PYTHON` → `/opt/homebrew/bin/python3` →
`/usr/local/bin/python3` → `/usr/bin/python3` 的顺序找第一个可执行的。

> ⚠️ Homebrew 的排在系统的前面是有意的：`/usr/bin/python3` 是个壳，
> 没装 Command Line Tools 时执行它会弹出「安装开发者工具」的系统对话框 ——
> 一个菜单栏小工具弹这个太唐突。
>
> 也不用 `/usr/bin/env python3`：GUI 应用从 Finder 启动时拿到的是
> LaunchServices 的默认 PATH，不是你 shell 里那个，conda / pyenv 的 python3
> 根本不在搜索范围内。

两级失败区别对待，与 `balance.py` 自己那套原则一致：

| 情况                                          | 表现                                       |
| --------------------------------------------- | ------------------------------------------ |
| 没配额度 / 找不到 `balance.py` / 没有 python3 | 整条区域**不出现**，一个像素都不占         |
| 某个渠道查失败（缺 key、鉴权失败、网络不通）  | 那一行显示原因。网络类瞬时失败用灰色、要动手改配置的用橙色 |
| 刷新失败但之前查到过                          | **保留上次的值**，靠那个明显偏旧的时间戳体现没刷上 |

实测窗口高度（单行明细 43pt，内屏可见高度 949pt）：

| 明细行数     | 1   | 2   | 3   | 4   | 5 行及以上    |
| ------------ | --- | --- | --- | --- | ------------- |
| 有余额区     | 636 | 679 | 722 | 765 | **794**（封顶，84%） |
| 无余额区     | 570 | 613 | 656 | 699 | 728           |

> 加余额区时把明细表上限从 235pt 降到了 200pt（同时可见 5 行 → 4 行）。
> 不降的话 5 行以上会到 829pt、占内屏 87%，而 87% 正是当初否掉「上限 300pt」
> 的理由。这个降幅**对没用额度功能的人也生效** —— 做成「有余额区才降」会让
> 窗口在额度查回来的那一刻缩 35pt，抖一下比少一行更难受。

## 回归自测

```bash
cd proxy
python3 selftest_usage.py
```

纯 stdlib `assert`，不引依赖、不需要测试框架。把上面「统计口径」里每条结论都钉成断言：
三种风格的归一化、两种缓存字段并存的混合形态、`message_delta` 权威覆盖、
Responses 的嵌套 usage 与嵌套 error、聚合路由的 URL 拼接与密钥注入，
以及额度解析的字段陷阱（字符串金额、`video` 条目、已用/剩余方向）。

改归一化或路由逻辑前后都跑一下。这些数字错了不会报错也不会崩，只会让界面上的值
静静地偏掉几万 —— 肉眼发现不了。

## 数据文件

- 按天生成 `proxy/ai_stats-YYYY-MM-DD.jsonl`，每行一条 JSON
- **写入方只有代理**，应用只读，避免两个进程互相干扰
- 应用按文件名读取当天数据，跨天自动切换（不做时间戳过滤）
- 过期文件由代理在启动时和跨天时自动清理
