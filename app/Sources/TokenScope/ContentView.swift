import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = StatsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsCards
            Divider()
            breakdownList
            Divider()
            footer
        }
        // ⚠️ 宽度别低于 464pt：表格 5 列固定宽度合计 392 + 列间距 8×5 + 左右
        // padding 32 = 464，再窄列就会互相挤压。480 留了 16pt 的 Spacer 余量。
        .frame(width: 480, height: 500)
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

    private var statsCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                statCard(icon: "arrow.down.circle", color: .blue,
                         title: "新增输入", value: formatTokenCount(viewModel.summary.newInputTokens))
                statCard(icon: "bolt.horizontal.circle", color: .green,
                         title: "缓存读取", value: formatTokenCount(viewModel.summary.cachedTokens))
                statCard(icon: "square.and.arrow.down.on.square", color: .orange,
                         title: "缓存写入", value: formatTokenCount(viewModel.summary.cacheCreationTokens))
                statCard(icon: "arrow.up.circle", color: .purple,
                         title: "输出", value: formatTokenCount(viewModel.summary.outputTokens))
            }
            cacheHitCard
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private func statCard(icon: String, color: Color, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.callout).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.rows) { row in
                            rowView(row)
                            if row.id != viewModel.rows.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 210)
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

    private func formatNumber(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatTokenCount(_ value: Int64) -> String {
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
    private func formatDuration(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        let seconds = Double(ms) / 1000
        // 阈值取 9.95 而非 10：否则 9970ms 会四舍五入成「10.0s」，
        // 与「≥10s 取整」自相矛盾。
        if seconds < 9.95 { return String(format: "%.1fs", max(seconds, 0.1)) }
        return String(format: "%.0fs", seconds)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
