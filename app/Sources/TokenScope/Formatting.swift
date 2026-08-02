import Foundation

// MARK: - 展示格式化
//
// 原本是 ContentView 的私有方法。趋势图的纵轴标签与悬停浮层也要用
// `formatTokenCount`，故提到模块级共用。函数名保持原样，调用点无需改动。

/// 千分位整数，如 815,579
func formatNumber(_ value: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    return f.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// token 数的中文量级缩写，如 5004.1万 / 1.23亿
func formatTokenCount(_ value: Int64) -> String {
    if value >= 100_000_000 { return String(format: "%.2f亿", Double(value) / 100_000_000) }
    if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
    return formatNumber(value)
}

/// 延迟一律以秒展示，两档精度：<10s 保留一位小数、≥10s 取整。
///
/// 不再输出 ms，是为了避免同一行里两个数字单位不一致 —— 首字延迟正好在
/// 1 秒上下晃，旧实现会渲染出「900ms / 1.2s」这种混排。统一成秒后
/// 值串也变短了（`300ms`→`0.3s`），顺带消掉了数值宽度反超标签的风险。
///
/// 不足 0.1s 的按 0.1s 兜底，免得显示成「0.0s」。
/// （实测本地代理场景首字最快 1.6s，这条分支基本不会触发。）
/// ⚠️ 耗时会超过 100s（实测有 106s 的请求），那时是 3 位数，属预期。
func formatDuration(_ ms: Int) -> String {
    guard ms > 0 else { return "—" }
    let seconds = Double(ms) / 1000
    // 阈值取 9.95 而非 10：否则 9970ms 会四舍五入成「10.0s」，
    // 与「≥10s 取整」自相矛盾。
    if seconds < 9.95 { return String(format: "%.1fs", max(seconds, 0.1)) }
    return String(format: "%.0fs", seconds)
}

/// footer 的「更新于 HH:mm:ss」
func timeString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

/// 只建一次。DateFormatter 的初始化不便宜（约几十微秒），而下面那个函数是在
/// 视图 body 里被调的 —— 鼠标在面板上动一下就重算一遍，别在那种路径上反复 new。
private let resetDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// 套餐额度的重置时刻，紧凑展示：今天只给时刻，跨天补上日期。
///
/// 入参是 balance.py 给的 `yyyy-MM-dd HH:mm`。这里只切字符串、不解析成 Date ——
/// 与 `AiStatsService.hour(from:)` 同一个理由，格式是自家代理写死的。
///
/// ⚠️ 跨天**必须**带上日期。MiniMax 的 7 天窗实测就落在次日 `00:00`，
/// 只显示「00:00」分不清是今天还是明天 —— 这个歧义是必然撞上的，不是理论情况。
/// 格式不符时原样返回，宁可显示得长一点也不显示错。
func formatResetTime(_ resetsAt: String) -> String {
    let parts = resetsAt.split(separator: " ")
    guard parts.count == 2, parts[0].count == 10 else { return resetsAt }

    let day = String(parts[0])
    let time = String(parts[1])
    if day == resetDayFormatter.string(from: Date()) { return time }
    return String(day.dropFirst(5)) + " " + time      // 2026-08-03 → 08-03
}
