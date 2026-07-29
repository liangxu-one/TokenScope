import SwiftUI

/// 分组维度
enum GroupDimension: String, CaseIterable, Identifiable {
    case provider = "渠道"
    case model = "模型"

    var id: String { rawValue }
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var snapshot: StatsSnapshot = .empty
    @Published var isLoading = false
    @Published var dimension: GroupDimension = .provider
    @Published var lastRefreshed: Date?

    private let service = AiStatsService()
    private var timer: Timer?

    /// 自动刷新间隔（秒）
    private let refreshInterval: TimeInterval = 30

    var summary: TodaySummary { snapshot.summary }

    /// 当前维度下的行数据
    var rows: [StatsRow] {
        switch dimension {
        case .provider: return snapshot.providers
        case .model: return snapshot.models
        }
    }

    // MARK: - 生命周期

    func startAutoRefresh() {
        refresh()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 刷新

    func refresh() {
        // 已在加载中就跳过，避免定时器与手动点击叠加
        guard !isLoading else { return }
        isLoading = true

        let service = self.service

        // 这里必须用 [self] 强引用而非 [weak self]：
        // 面板关闭时若 self 已被释放，弱引用会让 isLoading 永远停在 true，
        // 之后所有刷新都被上面的 guard 拦掉，界面彻底不再更新。
        // 强引用只多持有一次读取的时间，代价可以忽略。
        Task.detached(priority: .userInitiated) { [self] in
            let snapshot = service.fetchTodayStats()
            await MainActor.run {
                self.snapshot = snapshot
                self.lastRefreshed = Date()
                self.isLoading = false
            }
        }
    }
}
