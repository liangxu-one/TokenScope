import Foundation

/// 从代理写出的按天 jsonl 文件读取统计数据。
///
/// 设计约定：
/// - **本服务只读，绝不写入或删除数据文件。** 写入与清理均由 Python 代理负责，
///   避免两个进程同时操作同一文件导致记录丢失。
/// - 数据按天分文件（`ai_stats-YYYY-MM-DD.jsonl`），只读当天那一个文件。
struct AiStatsService {

    /// 统计文件所在目录
    private let statsDirectory: String

    /// 文件名前缀
    private static let filePrefix = "ai_stats-"
    private static let fileSuffix = ".jsonl"

    init(statsDirectory: String? = nil) {
        self.statsDirectory = statsDirectory ?? Self.resolveStatsDirectory()
    }

    /// 推算统计目录，依次尝试：
    /// 1. 环境变量 `TOKENSCOPE_STATS_DIR`
    /// 2. 从 .app 位置向上找仓库根的 `proxy/`（仓库内运行时命中）
    /// 3. `~/code/TokenScope/proxy` 作为归位
    ///
    /// 这样仓库整体换位置或 clone 到别的机器都不需要改代码。
    private static func resolveStatsDirectory() -> String {
        let fm = FileManager.default

        if let custom = ProcessInfo.processInfo.environment["TOKENSCOPE_STATS_DIR"],
           !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }

        // .app 通常位于 <repo>/app/TokenScope.app，向上逐层找 <repo>/proxy
        var dir = Bundle.main.bundleURL
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("proxy")
            if fm.fileExists(atPath: candidate.appendingPathComponent("http_proxy.py").path) {
                return candidate.path
            }
        }

        return ("~/code/TokenScope/proxy" as NSString).expandingTildeInPath
    }

    // MARK: - 读取

    /// 读取指定日期的全部记录。日期格式 yyyy-MM-dd。
    func loadStats(for dateString: String) -> [AiStat] {
        let path = "\(statsDirectory)/\(Self.filePrefix)\(dateString)\(Self.fileSuffix)"
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("读取失败: \(path)")
            return []
        }

        let decoder = JSONDecoder()
        var stats: [AiStat] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            // 单行损坏不影响整体，静默跳过。
            //
            // 这不只是防御性写法：代理正在追加写入时，这里可能读到只写了一半的
            // 最后一行。跳过它意味着最新那条记录会晚一个刷新周期才出现，
            // 这是有意的取舍——比加锁或等待要简单得多，且下次刷新自然就补上了。
            guard let stat = try? decoder.decode(AiStat.self, from: data) else { continue }
            stats.append(stat)
        }

        return stats
    }

    /// 读取今日数据并聚合
    func fetchTodayStats() -> StatsSnapshot {
        fetchStats(for: Self.todayString())
    }

    /// 读取并聚合指定日期的数据
    func fetchStats(for dateString: String) -> StatsSnapshot {
        let stats = loadStats(for: dateString)
        return Self.aggregate(stats, dateString: dateString)
    }

    /// 列出所有有数据的日期（降序），用于将来做趋势图
    func availableDates() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: statsDirectory) else {
            return []
        }

        return files
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(Self.fileSuffix) }
            .compactMap { name -> String? in
                let start = name.index(name.startIndex, offsetBy: Self.filePrefix.count)
                let end = name.index(name.endIndex, offsetBy: -Self.fileSuffix.count)
                let date = String(name[start..<end])
                // 只接受 yyyy-MM-dd
                return date.count == 10 ? date : nil
            }
            .sorted(by: >)
    }

    // MARK: - 聚合

    /// 把原始记录聚合成快照。
    ///
    /// ⚠️ 所有比率都是"先把 token 累加、最后统一相除"。
    /// 每条各算一次再平均是错的，会让一条小请求和一条十万 token 的请求权重相同。
    static func aggregate(_ stats: [AiStat], dateString: String) -> StatsSnapshot {
        var total = TokenAggregate()
        var byModel: [String: TokenAggregate] = [:]
        var byProvider: [String: TokenAggregate] = [:]
        var byHour: [Int: TokenAggregate] = [:]

        for stat in stats {
            total.add(stat)

            let model = stat.model.isEmpty ? "unknown" : stat.model
            byModel[model, default: TokenAggregate()].add(stat)

            let provider = stat.provider ?? "unknown"
            byProvider[provider, default: TokenAggregate()].add(stat)

            // 时间戳解析失败的记录只是不进趋势图，仍计入上面的总量
            if let hour = hour(from: stat.timestamp) {
                byHour[hour, default: TokenAggregate()].add(stat)
            }
        }

        let modelRows = byModel
            .map { StatsRow(name: $0.key, aggregate: $0.value) }
            .sorted { $0.totalTokens > $1.totalTokens }

        let providerRows = byProvider
            .map { StatsRow(name: $0.key, aggregate: $0.value) }
            .sorted { $0.totalTokens > $1.totalTokens }

        return StatsSnapshot(
            dateString: dateString,
            summary: TodaySummary(aggregate: total),
            models: modelRows,
            providers: providerRows,
            hourly: hourlySeries(byHour: byHour, dateString: dateString)
        )
    }

    /// 把小时分桶补零成连续序列，供趋势图直接消费。
    ///
    /// 上界：当天只画到当前小时（未来的小时留空没有意义，也和 cc-switch 的
    /// x 轴止于「现在」一致）；非当天则画满 23 点。
    /// `aggregate` 接受任意日期，虽然目前只有 `fetchTodayStats()` 在调，
    /// 但这里不假设一定是今天。
    private static func hourlySeries(byHour: [Int: TokenAggregate],
                                    dateString: String) -> [HourlyPoint] {
        let lastHour: Int
        if dateString == todayString() {
            lastHour = Calendar.current.component(.hour, from: Date())
        } else {
            lastHour = 23
        }

        // 数据里出现过比上界更晚的小时（比如系统时区被改过），一并纳入，
        // 否则那部分数据会被静默丢掉。
        let upperBound = max(lastHour, byHour.keys.max() ?? 0)

        return (0...upperBound).map { hour in
            if let aggregate = byHour[hour] {
                return HourlyPoint(hour: hour, aggregate: aggregate)
            }
            return HourlyPoint(hour: hour)
        }
    }

    /// 从时间戳里取小时。
    ///
    /// `AiStat.timestamp` 是代理写入的固定格式 `"2026-07-31 09:46:31"`，
    /// 第 11–12 位就是小时，直接切字符串。
    /// ⚠️ 不要换成 `DateFormatter` —— 每 30 秒要处理几百到几千条记录，
    /// 建 formatter 和解析完整日期的开销毫无必要。
    /// 格式不符时返回 nil，由调用方决定怎么处理。
    static func hour(from timestamp: String) -> Int? {
        guard timestamp.count >= 13 else { return nil }
        let start = timestamp.index(timestamp.startIndex, offsetBy: 11)
        let end = timestamp.index(start, offsetBy: 2)
        guard let hour = Int(timestamp[start..<end]), (0...23).contains(hour) else { return nil }
        return hour
    }

    // MARK: - 工具

    /// 当天日期字符串，用于拼出要读取的文件名。
    ///
    /// ⚠️ 必须使用**系统本地时区**，与写入方 Python 的 `datetime.now()` 保持一致。
    /// 若这里硬编码某个时区，用户改系统时区后会去读一个代理并没在写的文件，界面会空白。
    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

// MARK: - 快照

/// 一次读取的完整结果
struct StatsSnapshot {
    let dateString: String
    let summary: TodaySummary
    let models: [StatsRow]
    let providers: [StatsRow]
    /// 逐小时序列，已补零，供趋势图使用
    let hourly: [HourlyPoint]

    static let empty = StatsSnapshot(
        dateString: AiStatsService.todayString(),
        summary: .zero,
        models: [],
        providers: [],
        hourly: []
    )

    var isEmpty: Bool { summary.requestCount == 0 }
}
