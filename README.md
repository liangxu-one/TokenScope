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
  ai_stats_domains.json   路由配置（路径前缀 → 上游域名）
  stats_report.py         命令行报表工具
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

| 原地址 | 改为 |
|---|---|
| `https://api.deepseek.com/v1` | `http://127.0.0.1:12345/deepseek/v1` |
| `https://api.deepseek.com/anthropic/v1` | `http://127.0.0.1:12345/deepseek/anthropic/v1` |

> ⚠️ 必须用 `http://` 而非 `https://`。代理是纯 HTTP 服务，
> 用 https 连接会导致 TLS 握手包被当作 HTTP 请求解析而报错。

### 4. 构建并启动菜单栏应用

```bash
cd app
./build.sh run
```

图标出现在菜单栏右上角（⚡），点击查看统计。

## 统计口径

各厂商返回的 usage 字段语义不一致，代理会先做归一化再落盘。
判断依据**只看输入总量字段名**，与厂商、模型无关：

| 上游字段 | 语义 | 换算 |
|---|---|---|
| `input_tokens` | 不含缓存（Anthropic 风格） | `new_input = input_tokens` |
| `prompt_tokens` | 已含缓存（OpenAI 风格） | `new_input = prompt_tokens - cached` |

落盘后的字段：

| 字段 | 含义 |
|---|---|
| `new_input_tokens` | 纯新增输入，不含缓存 |
| `cached_tokens` | 缓存读取（命中） |
| `cache_creation_tokens` | 缓存写入（一次性建缓存开销） |
| `output_tokens` | 输出（含 reasoning） |

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

| 项目 | 倍率 |
|---|---|
| 新增输入 | 1.0 |
| 缓存读取 | 0.1 |
| 缓存写入 | **1.25**（5m）/ 2.0（1h） |
| 输出 | 1.0 |

实测中缓存写入常占总成本 80% 以上 —— 它是一次性开销但单价最高，
而缓存读取虽然量大却因 0.1 倍折扣而便宜。

### 流式 usage 的合并规则

Anthropic 协议的 usage 分两个事件下发，各家行为差异很大（实测）：

| 渠道 | `message_start` | `message_delta` |
|---|---|---|
| DeepSeek | `input=20837` | `input=20837`（一致） |
| MiniMax | `input=0` | `input=280` |
| 阿里云 | `input=24681`（粗估） | `input=6`（真值） |

因此 **`message_delta` 是权威终值，直接覆盖**；`message_start` 只用于填补尚为 0 的字段。
**不能取最大值** —— 否则阿里云的新增输入会被高估上万，命中率被严重低估。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `AI_PROXY_RETENTION_DAYS` | `3` | 统计文件保留天数，`0` 为永久保留 |
| `AI_PROXY_CAPTURE` | 关闭 | 设为 `1` 记录完整报文到 `proxy/captures/`，用于排查 token 对不上 |
| `TOKENSCOPE_STATS_DIR` | 自动 | 覆盖统计文件目录，默认从 app 位置推算仓库内的 `proxy/` |

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

## 数据文件

- 按天生成 `proxy/ai_stats-YYYY-MM-DD.jsonl`，每行一条 JSON
- **写入方只有代理**，应用只读，避免两个进程互相干扰
- 应用按文件名读取当天数据，跨天自动切换（不做时间戳过滤）
- 过期文件由代理在启动时和跨天时自动清理
