import SwiftUI
import Charts

// MARK: - 四项 token 系列

/// 四项 token 的名称、配色、图标的**唯一来源**。
///
/// 指标卡和趋势图图例都从这里取，避免两处各写一份然后漂移 —— 这个坑是真实的：
/// cc-switch 用「输出=绿、缓存命中=紫」，本 app 用「缓存读取=绿、输出=紫」，
/// 绿紫正好对调，两套混用会让人把系列看错。
///
/// ⚠️ `allCases` 的顺序同时决定指标卡和图例的排列，改这里会同时影响两处。
enum TokenSeries: String, CaseIterable, Identifiable {
    case newInput = "新增输入"
    case cacheRead = "缓存读取"
    case cacheWrite = "缓存写入"
    case output = "输出"

    var id: String { rawValue }
    var title: String { rawValue }

    var color: Color {
        switch self {
        case .newInput: .blue
        case .cacheRead: .green
        case .cacheWrite: .orange
        case .output: .purple
        }
    }

    var icon: String {
        switch self {
        case .newInput: "arrow.down.circle"
        case .cacheRead: "bolt.horizontal.circle"
        case .cacheWrite: "square.and.arrow.down.on.square"
        case .output: "arrow.up.circle"
        }
    }

    func value(in point: HourlyPoint) -> Int64 {
        switch self {
        case .newInput: point.newInputTokens
        case .cacheRead: point.cachedTokens
        case .cacheWrite: point.cacheCreationTokens
        case .output: point.outputTokens
        }
    }

    func value(in summary: TodaySummary) -> Int64 {
        switch self {
        case .newInput: summary.newInputTokens
        case .cacheRead: summary.cachedTokens
        case .cacheWrite: summary.cacheCreationTokens
        case .output: summary.outputTokens
        }
    }
}

// MARK: - 纵轴上限

/// 取 1/2/3/5/10 × 10ⁿ 阶梯里**严格大于**峰值的那一档。
///
/// 为什么不用 Swift Charts 的 `.automatic`：实测它为了凑整数刻度间隔经常跳到
/// 峰值的两倍（21万→40万、2137万→4000万），曲线只占一半画布高度。本项目
/// 绘图区只有 150pt，浪费不起。阶梯里多一档 3，能把曲线稳定压在 70% 左右。
///
/// 取「严格大于」而非「大于等于」是为了保证永远留有余量，曲线不顶到天花板。
/// 另一个好处是上限只在跨档时才变，面板每 30 秒刷新一次也不会持续抖动。
///
/// 峰值为 0（一整天没有请求）时返回 1万，避免 `log10(0)` 得到 -inf。
func trendAxisTop(_ peak: Int64) -> Double {
    guard peak > 0 else { return 10_000 }
    let value = Double(peak)
    let base = pow(10, floor(log10(value)))
    for multiple in [1.0, 2.0, 3.0, 5.0] where value < multiple * base {
        return multiple * base
    }
    return 10 * base
}

// MARK: - 趋势图

/// 当天逐小时的 token 使用趋势。
///
/// 画法照搬 cc-switch 的 `UsageTrendChart.tsx`（Recharts `AreaChart`）：
/// 面积 + 渐变填充（0.2 → 0）、`monotone` 插值、极简坐标轴（只留淡色横向网格）、
/// 悬停竖线 + 信息浮层。
///
/// ⚠️ 已知且刻意接受的局限：四条线共用一根纵轴，而缓存读取通常比其余三条大
/// 两个数量级（实测 143~190 倍），所以另外三条会贴在底部不可读 —— 这是
/// cc-switch 原作同样存在的现象，不是本实现的缺陷。要改需换双轴/对数轴/双图。
struct TrendChart: View {
    let points: [HourlyPoint]
    var plotHeight: CGFloat = 150

    @State private var hoveredHour: Int?

    /// 浮层宽度固定，好做右边缘翻转的计算
    private static let tooltipWidth: CGFloat = 138

    private var axisTop: Double {
        let peak = points.flatMap { p in TokenSeries.allCases.map { $0.value(in: p) } }.max() ?? 0
        return trendAxisTop(peak)
    }

    /// x 轴当前跨度（小时）。下限 1，避免退化成 0...0 那种画不出东西的域。
    private var lastHour: Int { max(points.last?.hour ?? 1, 1) }

    /// 刻度间隔：向上取整到 lastHour/6，把标签数稳定压在 6~7 个。
    /// 用向下取整的话 08:00 那会儿会算出 stride 1、排出 9 个标签，480pt 宽下太挤。
    private var xAxisStride: Int { max(1, (lastHour + 5) / 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("使用趋势").font(.caption).fontWeight(.semibold)
                Spacer()
                Text("当天").font(.caption2).foregroundStyle(.tertiary)
            }
            chart
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    // 四组 mark 拆成独立属性：全塞进一个 Chart{} 会让类型检查器超时
    // （实测报 "unable to type-check this expression in reasonable time"）。

    /// 面积：必须显式给 `series:` 和 `.unstacked`。
    /// `series:` 不给的话四条会被当成同一条首尾相连；`stacking` 默认是 `.standard`，
    /// 那样画出来是四项的**累加值**（实测纵轴会跑到四者之和），而 cc-switch 的
    /// Recharts `<Area>` 没有 `stackId`、是重叠的。
    /// 渐变也必须显式指定 —— `foregroundStyle(by:)` 只能给平色。
    @ChartContentBuilder
    private var areaMarks: some ChartContent {
        ForEach(TokenSeries.allCases) { series in
            ForEach(points) { point in
                AreaMark(
                    x: .value("小时", point.hour),
                    y: .value("token", series.value(in: point)),
                    series: .value("面积", series.title),
                    stacking: .unstacked
                )
                .foregroundStyle(
                    LinearGradient(colors: [series.color.opacity(0.20), series.color.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)
            }
        }
    }

    /// 线：用 `foregroundStyle(by:)` 参与配色标度，图例由此自动生成
    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(TokenSeries.allCases) { series in
            ForEach(points) { point in
                LineMark(
                    x: .value("小时", point.hour),
                    y: .value("token", series.value(in: point)),
                    series: .value("线", series.title)
                )
                .foregroundStyle(by: .value("系列", series.title))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
    }

    /// 只有一个小时的数据时，线和面积都画不出任何东西（没有线段可连），
    /// 整张图会是空白 —— 每天 00:00~00:59 正是这个状态。补一组点标记兜底。
    @ChartContentBuilder
    private var singlePointMarks: some ChartContent {
        if points.count <= 1 {
            ForEach(TokenSeries.allCases) { series in
                ForEach(points) { point in
                    PointMark(
                        x: .value("小时", point.hour),
                        y: .value("token", series.value(in: point))
                    )
                    .foregroundStyle(by: .value("系列", series.title))
                    .symbolSize(26)
                }
            }
        }
    }

    /// 悬停时的竖向指示线
    @ChartContentBuilder
    private var hoverRule: some ChartContent {
        if let hour = hoveredHour {
            RuleMark(x: .value("小时", hour))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    private var chart: some View {
        Chart {
            areaMarks
            lineMarks
            singlePointMarks
            hoverRule
        }
        .chartForegroundStyleScale(
            domain: TokenSeries.allCases.map(\.title),
            range: TokenSeries.allCases.map(\.color)
        )
        .chartYScale(domain: 0...axisTop)
        // x 轴必须显式定域。不设的话 domain 由数据推出，而 AxisMarks 的
        // stride(by: 3) 又会把它撑到下一个 3 的倍数 —— 于是一天里 x 轴会在
        // 13、16、19、22 点各跳一次，曲线横向被反复压缩。
        // 固定成「0…当前最后一个小时」：曲线始终铺满宽度、随时间向右生长，
        // 也和 cc-switch 的 x 轴止于「现在」一致。
        .chartXScale(domain: 0...lastHour)
        .chartXAxis {
            // 刻度间隔跟着已有的时段走，始终保持 6~8 个标签：
            // 固定 stride 3 的话，清晨只画得出一两个标签（0…1 点只命中 00:00），
            // 满一天又刚好 8 个。自适应后 01 点是每小时一个、下午是每 2 小时、
            // 深夜是每 4 小时。
            // 用显式刻度数组而不是 .stride(by:)：后者传变量时 Swift 会挑到
            // Calendar.Component 那个重载，编不过。
            AxisMarks(values: Array(stride(from: 0, through: lastHour, by: xAxisStride))) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                let hour = value.as(Int.self) ?? 0
                // 首尾刻度正好落在绘图区左右边缘，标签居中摆必然有一半在界外，
                // Swift Charts 遇到放不下的标签是**整个丢弃**（实测末尾的 15:00
                // 直接不渲染，给绘图区加 16pt 右边距也没用）。
                // 首个改左对齐、末个改右对齐，中间保持居中，六个标签就都在了。
                AxisValueLabel(
                    anchor: hour == 0 ? .topLeading : (hour == lastHour ? .topTrailing : .top)
                ) {
                    Text(String(format: "%02d:00", hour)).font(.system(size: 8))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(axisLabel(tokens)).font(.system(size: 8))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .center, spacing: 4)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredHour = hour(at: location, proxy: proxy, geo: geo)
                            case .ended:
                                hoveredHour = nil
                            }
                        }

                    if let hour = hoveredHour,
                       let point = points.first(where: { $0.hour == hour }) {
                        tooltip(point)
                            .offset(x: tooltipX(for: hour, proxy: proxy, geo: geo), y: 0)
                            .allowsHitTesting(false)   // 浮层不能挡住悬停区
                    }
                }
            }
        }
        .frame(height: plotHeight)
    }

    /// 纵轴刻度专用格式化：整数档位不带小数尾巴。
    ///
    /// 不直接用 `formatTokenCount` —— 那个是给正文数值设计的，固定一位小数
    /// （`5004.1万` 需要），套到轴上会得到「3000.0万」「50.0万」这种啰嗦标签。
    /// 阶梯上限本身就是 1/2/3/5/10 的整数档，刻度基本都是整数万。
    private func axisLabel(_ tokens: Double) -> String {
        guard tokens > 0 else { return "0" }
        if tokens >= 100_000_000 {
            let yi = tokens / 100_000_000
            return yi == yi.rounded() ? String(format: "%.0f亿", yi) : String(format: "%.2f亿", yi)
        }
        if tokens >= 10_000 {
            let wan = tokens / 10_000
            return wan == wan.rounded() ? String(format: "%.0f万", wan) : String(format: "%.1f万", wan)
        }
        return formatNumber(Int64(tokens))
    }

    // MARK: 悬停

    /// 把鼠标位置反查成小时。`proxy.value(atX:)` 要的是相对绘图区原点的坐标。
    private func hour(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geo[anchor]
        guard plot.contains(location) else { return nil }
        guard let raw: Int = proxy.value(atX: location.x - plot.minX) else { return nil }
        // 反查值可能落在数据范围之外（边缘、或插值取整），收敛到实际区间
        guard let last = points.last?.hour else { return nil }
        return min(max(raw, 0), last)
    }

    /// 浮层横向位置：默认放在竖线右侧，靠近右边缘时翻到左侧，避免被窗口裁掉。
    private func tooltipX(for hour: Int, proxy: ChartProxy, geo: GeometryProxy) -> CGFloat {
        guard let anchor = proxy.plotFrame else { return 0 }
        let plot = geo[anchor]
        let lineX = plot.minX + (proxy.position(forX: hour) ?? 0)
        let gap: CGFloat = 8
        let right = lineX + gap
        if right + Self.tooltipWidth > geo.size.width {
            return max(lineX - Self.tooltipWidth - gap, 0)
        }
        return right
    }

    private func tooltip(_ point: HourlyPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%02d:00", point.hour))
                .font(.caption2).fontWeight(.semibold)
            ForEach(TokenSeries.allCases) { series in
                HStack(spacing: 4) {
                    Circle().fill(series.color).frame(width: 5, height: 5)
                    Text(series.title).font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(formatTokenCount(series.value(in: point)))
                        .font(.system(size: 9)).fontWeight(.medium).monospacedDigit()
                }
            }
        }
        .padding(6)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(radius: 3, y: 1)
    }
}
