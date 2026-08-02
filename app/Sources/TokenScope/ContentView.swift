import SwiftUI

/// 明细列表内容的实测高度，用来给 ScrollView 定高（见 breakdownList 的说明）
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 余额区内容的实测高度。
///
/// ⚠️ 必须与 `ListHeightKey` 分开，不能两个 ScrollView 共用一个 key。
/// `reduce` 取的是 `max`，共用的话两处 GeometryReader 会把彼此的高度顶成
/// 两者中的较大值 —— 结果是余额区跟着明细表一起被撑到 200pt 高。
private struct BalanceHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    @StateObject private var viewModel = StatsViewModel()

    /// 明细行内容撑起来的高度，由 GeometryReader 量出
    @State private var listContentHeight: CGFloat = 0

    /// 余额行内容撑起来的高度，同样由 GeometryReader 量出
    @State private var balanceContentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TrendChart(points: viewModel.snapshot.hourly)
            Divider()
            statsCards
            // 没有可查询额度的渠道时整条不出现，一个像素都不占 ——
            // 与 balance.py 的原则一致：认不出的渠道完全不显示，不打扰。
            // （注意明细上限从 235 降到 200 是**无条件**的，那部分不用额度的人
            // 也会受影响，少一行可见明细。理由见 breakdownList 里的说明。）
            if let balance = viewModel.balance, !balance.items.isEmpty {
                Divider()
                balanceStrip(balance)
            }
            Divider()
            breakdownList
            Divider()
            footer
        }
        // ⚠️ 宽度别低于 464pt：表格 5 列固定宽度合计 392 + 列间距 8×5 + 左右
        // padding 32 = 464，再窄列就会互相挤压。480 留了 16pt 的 Spacer 余量。
        //
        // 高度**不写死**，由内容撑开：写死的话行数少时底部会空一大片
        // （实测 700pt 下只有 2 行渠道，尾部白掉约 87pt）。
        //
        // 实测窗口高度（含余额区、2 个渠道，单行明细 43pt）：
        //   1 行 636pt　2 行 679　3 行 722　4 行 765　5 行及以上 794（封顶）
        // 不显示余额区时各减 66pt：1 行 570 … 5 行及以上 728。
        // 内屏可见高度 949pt，最坏情况 794 占 84%。
        //
        // 两处增长都被显式 height 封住：明细区见 breakdownList，
        // 余额区见 balanceMaxHeight。**不能有第三个可自由伸缩的区域** ——
        // 那样几个区域会互相抢剩余空间，谁也算不准。
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日真实消耗 Tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatNumber(viewModel.summary.realConsumedTokens))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("不含缓存读取")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("总 token \(formatTokenCount(viewModel.summary.totalTokens))　·　计费等效 \(formatTokenCount(Int64(viewModel.summary.billableTokens)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                statBadge(
                    icon: "arrow.left.arrow.right",
                    label: "请求数",
                    value: viewModel.summary.failedCount > 0
                        ? "\(viewModel.summary.requestCount)  (失败 \(viewModel.summary.failedCount))"
                        : "\(viewModel.summary.requestCount)",
                    color: viewModel.summary.failedCount > 0 ? .orange : .blue
                )
                // ⚠️ 两行延迟必须套在 .leading 的 VStack 里，别拆回外层。
                //
                // 徽标宽度 = 图标 14 + 间距 6 + max(标签宽, 数值宽)，外层是 .trailing
                // 对齐，只对齐右边缘 —— 两个徽标宽度一旦不同，图标和数值就阶梯状参差
                // （历史问题：「首字延迟 P50」比「耗时 P50 / P95」窄 8.4pt）。
                //
                // 光靠标签等字数不够：汉字等宽，两个 2 字标签实测都是 70.27pt，
                // 但数值可能比标签更宽 —— 首字延迟 P50/P95 双双跌破 1s 时格式化成
                // 「999ms / 999ms」实测 86.36pt，反超标签 16pt，参差就回来了。
                // 这里改用 .leading 让两行左边缘互相对齐，与字符串宽度无关；
                // 标签等字数则额外保证右边缘也齐平（这是锦上添花，不是对齐的前提）。
                //
                // 请求数徽标故意留在外层 .trailing，维持原有观感。
                VStack(alignment: .leading, spacing: 5) {
                    statBadge(
                        icon: "timer",
                        label: "首字 P50 / P95",
                        value: "\(formatDuration(viewModel.summary.ttftP50)) / \(formatDuration(viewModel.summary.ttftP95))",
                        color: .teal
                    )
                    statBadge(
                        icon: "clock",
                        label: "耗时 P50 / P95",
                        value: "\(formatDuration(viewModel.summary.durationP50)) / \(formatDuration(viewModel.summary.durationP95))",
                        color: .indigo
                    )
                }
            }
        }
        .padding(16)
    }

    /// 徽标：图标 + 标签在上、数值在下，数值贴右。
    ///
    /// 文字块用 .trailing，于是块内较窄的那行被推到右边。常态下标签比数值宽，
    /// 效果就是「标签不动、数值贴右」；反过来数值更宽时（如请求数带失败计数
    /// 「287  (失败 2)」）则是标签被顶到最右边 —— 这是刻意接受的行为。
    private func statBadge(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .trailing, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption).fontWeight(.semibold)
            }
        }
    }

    // MARK: - 指标卡

    /// 四张 token 卡。名称/配色/图标全部来自 `TokenSeries`，与趋势图图例共用同一份定义，
    /// 顺序也由 `TokenSeries.allCases` 决定 —— 两处永远一致，不会各改一处然后对不上。
    private var statsCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(TokenSeries.allCases) { series in
                    statCard(icon: series.icon, color: series.color,
                             title: series.title,
                             value: formatTokenCount(series.value(in: viewModel.summary)))
                }
            }
            cacheHitCard
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    /// 一张 token 卡。内容**居中**，不是左对齐。
    ///
    /// 四张卡等宽平分整行，标题字数却不一样（「新增输入」4 字、「输出」2 字），
    /// 左对齐时数值会各自贴在自己那格的左边缘、离标题中心一远一近，看着像没对齐。
    /// 居中之后每格自成一个小单元，与下面「缓存命中率」那条整行卡不冲突。
    private func statCard(icon: String, color: Color, title: String, value: String) -> some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.callout).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var cacheHitCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                Text("缓存命中率").font(.caption2).foregroundStyle(.secondary)

                Text("Σ缓存读 / Σ真实总输入")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text("\(formatTokenCount(viewModel.summary.cachedTokens)) / \(formatTokenCount(viewModel.summary.hitRateDenominator))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", viewModel.summary.cacheHitRate))
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(hitRateColor(viewModel.summary.cacheHitRate))
            }
            ProgressView(value: min(viewModel.summary.cacheHitRate, 100), total: 100)
                .tint(hitRateColor(viewModel.summary.cacheHitRate))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// 命中率配色阈值。
    ///
    /// 阈值按“分母含缓存写入”的口径设定：该口径下建缓存的开销也计入分母，
    /// 数值天然低于 new-api 那种口径（实测同一份数据 65% vs 98%），
    /// 因此 60% 已属良好，不能沿用 80/50 那套阈值。
    private func hitRateColor(_ rate: Double) -> Color {
        if rate >= 60 { return .green }
        if rate >= 30 { return .orange }
        return .red
    }

    /// 已用百分比配色。
    ///
    /// ⚠️ 阈值方向与 `hitRateColor` **相反**，别复用那个：
    /// 命中率越高越好（高 = 绿），已用比例越高越糟（高 = 红）。
    /// 两个函数都收 0~100 的 Double，混用编译器不会报错，只会把颜色配反。
    private func usedColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }

    // MARK: - 剩余额度
    //
    // 数据来自 BalanceService（跑 `balance.py --json` 子进程），刷新周期与统计
    // 分开：统计读本地文件 30 秒一次，额度要联网 5 分钟一次。所以这里自带
    // 抓取时间与刷新按钮 —— 用底部那个「更新于」会让人以为余额也是 30 秒前的。

    /// 余额区上限：4 行内容。
    ///
    /// 实测每渠道一行占 17pt，取 76 而不是 68（正好 4 行）是为了让第 5 行露
    /// 出 8pt —— 与明细表同一个道理：macOS 的滚动条是覆盖式的，不滚动时不显示，
    /// 卡在整行边界上看起来就像"到此为止了"。
    /// 4 行以内不会触发滚动，也就是绝大多数人根本遇不到。
    private static let balanceMaxHeight: CGFloat = 76

    private func balanceStrip(_ balance: BalanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行放在 ScrollView **外面**：渠道多到要滚时，抓取时间和刷新
            // 按钮不该跟着滚走。
            HStack(spacing: 6) {
                Image(systemName: "creditcard").font(.caption2).foregroundStyle(.cyan)
                Text("剩余额度").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !balance.shortTime.isEmpty {
                    // 查询中用淡出表示，不塞 ProgressView —— 小号转圈比 caption2
                    // 还高，会把整行顶起来，每次刷新窗口都抖一下。
                    Text(balance.shortTime)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .opacity(viewModel.isBalanceLoading ? 0.35 : 1)
                }
                Button { viewModel.refreshBalance() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("立即重新查询各渠道额度（要联网）")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(balance.items) { balanceRow($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: BalanceHeightKey.self, value: geo.size.height)
                    }
                )
            }
            // 与明细表同样必须给**显式高度**，理由见 breakdownList 里的长注释：
            // ScrollView 没有固有内容高度，窗口高度不写死时它会被动吸收差额、塌成 0。
            .frame(height: min(max(balanceContentHeight, 1), Self.balanceMaxHeight))
            .onPreferenceChange(BalanceHeightKey.self) { balanceContentHeight = $0 }
        }
        .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
    }

    private func balanceRow(_ item: BalanceItem) -> some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 76, alignment: .leading)
            balanceValue(item.value)
            Spacer(minLength: 0)
        }
        .help(balanceTooltip(item))
    }

    @ViewBuilder
    private func balanceValue(_ value: BalanceValue) -> some View {
        switch value {
        case let .currency(amounts, available):
            HStack(spacing: 10) {
                // 多币种账户各币种独立，**不能相加**，所以并排列出。
                // 按下标遍历而不是按币种做 id —— 理由见 MoneyAmount 的注释。
                ForEach(Array(amounts.enumerated()), id: \.offset) { _, amount in
                    Text(amount.text)
                        .font(.caption).fontWeight(.semibold)
                        // 金额不做阈值配色：多少算"低"取决于你的消耗速度，
                        // 编一个阈值只会误导。唯一变红的依据是上游自己说余额不足。
                        .foregroundStyle(available ? Color.primary : .red)
                }
                if !available {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)).foregroundStyle(.red)
                }
            }

        case let .quota(windows):
            HStack(spacing: 14) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 4) {
                        Text(window.label).font(.system(size: 9)).foregroundStyle(.tertiary)
                        // 必须写"已用" —— 只写 1% 会被读成"只剩 1%"，语义正好反过来
                        Text("已用 \(Int(window.usedPercent.rounded()))%")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(usedColor(window.usedPercent))
                        miniBar(window.usedPercent)

                        if let resetsAt = window.resetsAt {
                            // 时钟图标不是装饰：一个光秃秃的「20:00」跟在进度条后面
                            // 读不出是什么，可能被当成任何时刻。
                            HStack(spacing: 2) {
                                Image(systemName: "clock").font(.system(size: 8))
                                Text(formatResetTime(resetsAt)).font(.system(size: 9))
                            }
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            // 渠道给了 3 个以上窗口时宁可截断也不换行 —— 换行会把行高顶成两倍，
            // 连带撑破余额区那个 76pt 的封顶。
            .lineLimit(1)

        case let .failure(message, transient):
            HStack(spacing: 4) {
                Image(systemName: transient ? "wifi.slash" : "exclamationmark.circle")
                    .font(.system(size: 8))
                Text(message)
                    .font(.caption2).lineLimit(1).truncationMode(.tail)
            }
            // 瞬时失败（网络不通）用灰色：过会儿自己就好了，不值得报警；
            // 非瞬时（缺 key、鉴权失败）是要你动手改配置的，用橙色。
            .foregroundStyle(transient ? Color.secondary : Color.orange)
        }
    }

    /// 已用比例的迷你条。只有套餐额度画得出来 —— 货币余额没有分母，
    /// 不知道"满"是多少，所以那类行右边是空的，不是漏了。
    private func miniBar(_ percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(usedColor(percent))
                    // 下限 1.5pt：已用 0% 时也留一个点，否则整条看着像没渲染出来
                    .frame(width: max(geo.size.width * min(percent, 100) / 100, 1.5))
            }
        }
        .frame(width: 26, height: 3)
    }

    private func balanceTooltip(_ item: BalanceItem) -> String {
        switch item.value {
        case let .currency(amounts, available):
            let money = amounts.map { "\($0.code) \($0.text)" }.joined(separator: "　")
            return """
                \(item.name)　货币余额
                \(money)
                \(available ? "上游标记为可用" : "⚠️ 上游标记余额不足")
                货币余额没有重置周期，只能靠充值回升。
                """
        case let .quota(windows):
            let detail = windows.map {
                "\($0.label)　已用 \(String(format: "%.1f", $0.usedPercent))%　剩余 "
                    + "\(String(format: "%.1f", 100 - $0.usedPercent))%"
                    + ($0.resetsAt.map { "　重置于 \($0)" } ?? "")
            }.joined(separator: "\n")
            return "\(item.name)　套餐额度（无面值）\n\(detail)"
        case let .failure(message, transient):
            // 不再套一层「查询失败」——message 自己就说清了是什么（鉴权失败 /
            // 网络不可达 / 版本不匹配），外面再加一句反而会把非查询类的问题
            // 也说成查询失败。
            return "\(item.name)\n\(message)"
                + (transient ? "\n网络类瞬时失败，下次刷新会重试。" : "")
        }
    }

    // MARK: - 分组明细

    private var breakdownList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $viewModel.dimension) {
                    ForEach(GroupDimension.allCases) { dim in
                        Text(dim.rawValue).tag(dim)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()

                Spacer()

                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button { viewModel.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("立即刷新")
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))

            if viewModel.snapshot.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text("今日暂无数据").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // ⚠️ 这里必须给 ScrollView 一个**显式高度**，不能只写 maxHeight。
                //
                // ScrollView 没有固有内容高度：它会接受容器给的任何高度提案。
                // 窗口高度不写死时，它就成了整个 VStack 里唯一可伸缩的元素，
                // 被动吸收「容器高度 - 其余固定部分」这个差额 —— 在菜单栏弹窗里
                // 这个差额算出来是 0，列表整个消失（实测真机复现）。
                //
                // 所以先用 GeometryReader 量出行内容的真实高度，再显式设定。
                // 不写死行高是刻意的：行高取决于字号和 padding，硬编码一个 42
                // 等于把版面算术又抄一份，改字号就失效。
                //
                // 上限 200pt：单行 43pt（42 + 分隔线），200 = 4 整行 + 第 5 行
                // 露出 28pt。这个"露半行"是必要的：macOS 的滚动条是覆盖式的，
                // 不滚动时不显示，若上限卡在整行边界（172 = 4 行整、215 = 5 行整）
                // 或只差一点（220 只露 5pt），看上去就像列表到此为止了。
                //
                // 原本是 235pt（5 整行 + 露 20pt），加余额区时降下来的：
                // 余额区在 2 渠道下占 66pt，明细若仍留 235，6 行以上时窗口会到
                // 829pt、占掉内屏可见高度（949pt）的 87% —— 那正是当初否掉
                // 「上限 300pt」的同一个理由。降到 200 后是 794pt / 84%。
                // 顺带一提 200 的滚动提示（露 28pt）比 235（露 20pt）更明显，
                // 因为 200 落在一行中间、而 235 刚过行边界。
                // 唯一的代价：同时可见的明细行数从 5 变 4。
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.rows) { row in
                            rowView(row)
                            if row.id != viewModel.rows.last?.id { Divider() }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: min(max(listContentHeight, 1), 200))
                .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
            }
        }
    }

    private func rowView(_ row: StatsRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("\(row.requestCount) 次")
                        .font(.caption2).foregroundStyle(.secondary)
                    if row.failedCount > 0 {
                        Text("失败 \(row.failedCount)")
                            .font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .frame(width: 132, alignment: .leading)

            // token 分解
            VStack(alignment: .leading, spacing: 2) {
                tokenLine(icon: "arrow.down", color: .blue, value: row.newInputTokens)
                tokenLine(icon: "arrow.up", color: .purple, value: row.outputTokens)
            }
            .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                tokenLine(icon: "bolt.fill", color: .green, value: row.cachedTokens)
                if row.cacheCreationTokens > 0 {
                    tokenLine(icon: "square.and.arrow.down", color: .orange, value: row.cacheCreationTokens)
                }
            }
            .frame(width: 74, alignment: .leading)

            Spacer(minLength: 0)

            // 命中率
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f%%", row.cacheHitRate))
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(hitRateColor(row.cacheHitRate))
                Text("命中率").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 52, alignment: .trailing)

            // 延迟（均为 P50，P95 见 header 与 tooltip）
            VStack(alignment: .trailing, spacing: 2) {
                latencyLine(prefix: "首", value: formatDuration(row.ttftP50), color: .teal)
                latencyLine(prefix: "总", value: formatDuration(row.durationP50), color: .secondary)
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        .help("""
            \(row.name)
            新增输入 \(formatNumber(row.newInputTokens))
            缓存读取 \(formatNumber(row.cachedTokens))
            缓存写入 \(formatNumber(row.cacheCreationTokens))
            输出 \(formatNumber(row.outputTokens))
            真实总输入 \(formatNumber(row.totalInputTokens))
            命中率 \(formatNumber(row.cachedTokens)) / \(formatNumber(row.hitRateDenominator)) = \(String(format: "%.2f%%", row.cacheHitRate))
            计费等效 \(formatNumber(Int64(row.billableTokens)))
            首字 P50 \(formatDuration(row.ttftP50))　耗时 P50 \(formatDuration(row.durationP50))
            """)
    }

    /// 延迟一行：单字前缀 + 数值。
    /// 「首」= 首字延迟、「总」= 总耗时，与 header 的「首字 / 耗时」同一套词；
    /// 加前缀是因为原来两个裸数字只靠青色/灰色区分，不悬停看 tooltip 读不出谁是谁。
    private func latencyLine(prefix: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(prefix).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.caption2).foregroundStyle(color)
        }
    }

    private func tokenLine(icon: String, color: Color, value: Int64) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8)).foregroundStyle(color)
            Text(formatTokenCount(value)).font(.caption2)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Text(viewModel.snapshot.dateString)
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if let refreshed = viewModel.lastRefreshed {
                Text("更新于 \(timeString(refreshed))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(EdgeInsets(top: 7, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - 格式化
    //
    // formatNumber / formatTokenCount / formatDuration / timeString 已移到
    // Formatting.swift —— 趋势图的纵轴与悬停浮层也需要它们。函数名未变。
}
