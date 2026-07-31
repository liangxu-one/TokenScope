import Foundation

// MARK: - 磁盘记录

/// ai_stats-YYYY-MM-DD.jsonl 中的单条记录。
/// 由 proxy/http_proxy.py 写入，token 已做跳协议归一化。
struct AiStat: Codable {
    let timestamp: String
    let provider: String?
    let model: String
    let apiFormat: String?
    let path: String?
    let stream: Bool?
    let statusCode: Int?
    let durationMs: Int?
    let ttftMs: Int?
    let tokens: TokenInfo
    let error: String?

    enum CodingKeys: String, CodingKey {
        case timestamp, provider, model, path, stream, tokens, error
        case apiFormat = "api_format"
        case statusCode = "status_code"
        case durationMs = "duration_ms"
        case ttftMs = "ttft_ms"
    }

    var isSuccess: Bool {
        error == nil && (statusCode ?? 200) == 200
    }
}

/// 归一化后的 token 明细。
///
/// 各字段语义（代理侧已消除厂商差异）：
/// - `newInputTokens`：纯新增输入，**不含**缓存命中部分
/// - `cachedTokens`：缓存读取（命中）
/// - `cacheCreationTokens`：缓存写入，一次性建缓存开销
/// - `outputTokens`：输出（含 reasoning）
struct TokenInfo: Codable {
    let newInputTokens: Int64
    let cachedTokens: Int64
    let cacheCreationTokens: Int64
    let outputTokens: Int64

    enum CodingKeys: String, CodingKey {
        case newInputTokens = "new_input_tokens"
        case cachedTokens = "cached_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case outputTokens = "output_tokens"
    }

    /// 真实总输入：新增 + 缓存读 + 缓存写
    var totalInputTokens: Int64 {
        newInputTokens + cachedTokens + cacheCreationTokens
    }

    /// 缓存命中率的分母 = 真实总输入（**含缓存写入**，不含输出）。
    ///
    /// 回答的是「全部输入 token 里有多少是靠缓存复用的」。
    /// ⚠️ 与 new-api 口径不同（它的分母只含 new_input + cached），
    /// 这是刻意选择，详见 proxy/http_proxy.py 文件头说明。
    var hitRateDenominator: Int64 {
        totalInputTokens
    }

    var totalTokens: Int64 {
        totalInputTokens + outputTokens
    }
}

// MARK: - 聚合器

/// Token 聚合器。
///
/// ⚠️ 核心约定：**只累加原始 token 总量，比率一律在最后由总量相除得出**。
/// 绝不能对每条请求各算一次比率再取平均 —— 那样大小请求权重相同，结果无意义。
/// new-api 后端同样是累加原始量（`service/channel_affinity.go:857-871`）。
struct TokenAggregate {
    var requestCount = 0
    var failedCount = 0

    var newInputTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var outputTokens: Int64 = 0

    /// 各请求的首字延迟，用于算分位数。
    /// ⚠️ 非流式请求（`stream=false`）拿不到首字，代理侧记的是 null，
    /// 所以本数组长度可能小于 `durations` —— 两组分位数的样本集并不严格相同。
    private(set) var ttfts: [Int] = []
    /// 各请求的总耗时，用于算分位数
    private(set) var durations: [Int] = []

    mutating func add(_ stat: AiStat) {
        requestCount += 1
        if !stat.isSuccess {
            failedCount += 1
        }

        newInputTokens += stat.tokens.newInputTokens
        cachedTokens += stat.tokens.cachedTokens
        cacheCreationTokens += stat.tokens.cacheCreationTokens
        outputTokens += stat.tokens.outputTokens

        if let ttft = stat.ttftMs, ttft > 0 { ttfts.append(ttft) }
        if let duration = stat.durationMs, duration > 0 { durations.append(duration) }
    }

    // MARK: 派生指标（全部基于已汇总的总量）

    var totalInputTokens: Int64 { newInputTokens + cachedTokens + cacheCreationTokens }

    var totalTokens: Int64 { totalInputTokens + outputTokens }

    /// 命中率分母 = 真实总输入（含缓存写入）
    var hitRateDenominator: Int64 { totalInputTokens }

    /// 缓存命中率 = Σcached / Σtotal_input，先汇总再相除
    var cacheHitRate: Double {
        hitRateDenominator > 0
            ? Double(cachedTokens) * 100.0 / Double(hitRateDenominator)
            : 0
    }

    /// 计费等效 token。倍率取 new-api 默认值
    /// （`setting/ratio_setting/cache_ratio.go`：缓存读 0.1、缓存写 1.25）。
    /// 仅用于横向比较成本量级，不等于真实账单。
    var billableTokens: Double {
        Double(newInputTokens)
            + Double(cachedTokens) * 0.1
            + Double(cacheCreationTokens) * 1.25
            + Double(outputTokens)
    }

    func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count) * p / 100), sorted.count - 1)
        return sorted[index]
    }

    var ttftP50: Int { percentile(ttfts, 50) }
    var ttftP95: Int { percentile(ttfts, 95) }
    var durationP50: Int { percentile(durations, 50) }
    var durationP95: Int { percentile(durations, 95) }
}

// MARK: - 展示模型

/// 按某个维度（模型 / 渠道）聚合后的展示数据
struct StatsRow: Identifiable {
    let id: String
    let name: String

    let requestCount: Int
    let failedCount: Int

    let newInputTokens: Int64
    let cachedTokens: Int64
    let cacheCreationTokens: Int64
    let outputTokens: Int64

    let hitRateDenominator: Int64
    let totalInputTokens: Int64
    let totalTokens: Int64
    let cacheHitRate: Double
    let billableTokens: Double

    let ttftP50: Int
    let durationP50: Int

    init(name: String, aggregate: TokenAggregate) {
        self.id = name
        self.name = name
        self.requestCount = aggregate.requestCount
        self.failedCount = aggregate.failedCount
        self.newInputTokens = aggregate.newInputTokens
        self.cachedTokens = aggregate.cachedTokens
        self.cacheCreationTokens = aggregate.cacheCreationTokens
        self.outputTokens = aggregate.outputTokens
        self.hitRateDenominator = aggregate.hitRateDenominator
        self.totalInputTokens = aggregate.totalInputTokens
        self.totalTokens = aggregate.totalTokens
        self.cacheHitRate = aggregate.cacheHitRate
        self.billableTokens = aggregate.billableTokens
        self.ttftP50 = aggregate.ttftP50
        self.durationP50 = aggregate.durationP50
    }
}

/// 当日总览
struct TodaySummary {
    var requestCount = 0
    var failedCount = 0

    var newInputTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0
    var outputTokens: Int64 = 0

    var hitRateDenominator: Int64 = 0
    var totalInputTokens: Int64 = 0
    var totalTokens: Int64 = 0
    var cacheHitRate: Double = 0
    var billableTokens: Double = 0

    var ttftP50 = 0
    var ttftP95 = 0
    var durationP50 = 0
    var durationP95 = 0

    static let zero = TodaySummary()

    init() {}

    init(aggregate: TokenAggregate) {
        requestCount = aggregate.requestCount
        failedCount = aggregate.failedCount
        newInputTokens = aggregate.newInputTokens
        cachedTokens = aggregate.cachedTokens
        cacheCreationTokens = aggregate.cacheCreationTokens
        outputTokens = aggregate.outputTokens
        hitRateDenominator = aggregate.hitRateDenominator
        totalInputTokens = aggregate.totalInputTokens
        totalTokens = aggregate.totalTokens
        cacheHitRate = aggregate.cacheHitRate
        billableTokens = aggregate.billableTokens
        ttftP50 = aggregate.ttftP50
        ttftP95 = aggregate.ttftP95
        durationP50 = aggregate.durationP50
        durationP95 = aggregate.durationP95
    }

    /// 真实消耗（不含缓存读取，因为那部分基本不花钱）
    var realConsumedTokens: Int64 {
        newInputTokens + cacheCreationTokens + outputTokens
    }
}
