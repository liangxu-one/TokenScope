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

    /// 各渠道剩余额度。nil = 这台机器上没有这个功能（没配 / 没 python3），界面整条隐藏。
    @Published var balance: BalanceSnapshot? = StatsViewModel.cachedBalance
    @Published var isBalanceLoading = false

    /// 额度状态挂在**类型上**而不是实例上。
    ///
    /// ⚠️ 这不是图省事：`MenuBarExtra` 的内容视图在弹窗每次打开时可能被重建，
    /// 连带 `@StateObject` 里的 StatsViewModel 一起换新。状态放实例上的话，
    /// 节流时间戳和已取到的值会跟着丢，表现是两个都很糟的 bug：
    ///   1. 每开一次面板就往各厂商打一轮请求（节流形同虚设）
    ///   2. 面板每次都先没有余额区、约 1 秒后才冒出来，窗口高度当场跳一下
    /// 挂在类型上，作用域就是"进程存活期间"——正好是这份缓存该有的寿命。
    private static var cachedBalance: BalanceSnapshot?

    /// 上次**尝试**取额度的时刻（成功失败都记）。
    ///
    /// 存尝试时间而不是成功时间，是为了给失败也加上节流 —— 否则 python3 缺失
    /// 这类必然失败的情况会变成每 30 秒空跑一个子进程。
    private static var balanceAttemptedAt: Date?

    private let service = AiStatsService()
    private let balanceService = BalanceService()
    private var timer: Timer?

    /// 自动刷新间隔（秒）
    private let refreshInterval: TimeInterval = 30

    /// 额度刷新间隔。比统计刷新慢得多，因为它要**联网**打各厂商的接口，
    /// 而统计只是读本地文件。30 秒一次纯属骚扰上游。
    private let balanceInterval: TimeInterval = 300

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
        // 从进程级缓存对一次表。
        //
        // 光靠属性初始值不够：若上一个 StatsViewModel 发起的查询是在本实例
        // 建好**之后**才回来的，新值只会写进那个旧实例和静态缓存，本实例手里
        // 还是更早的快照。不补这一句，面板会拿着旧值一直显示到下次节流到期
        // （最多 5 分钟），而正确的值其实早就在缓存里躺着了。
        balance = Self.cachedBalance

        refresh()
        refreshBalanceIfStale()
        guard timer == nil else { return }

        // 只有一个定时器，两个节奏 —— 额度那路靠时间戳自己判断该不该动，
        // 不再单开一个 Timer。少一个要 invalidate 的东西就少一处泄漏的可能。
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshBalanceIfStale()
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

    // MARK: - 额度

    /// 攒够间隔了才真去查。
    ///
    /// ⚠️ 这个节流是必需的，不是优化：菜单栏弹窗每次打开都会走 `onAppear`
    /// → `startAutoRefresh()`，要是无条件查一次，用户开关十次面板就往各厂商
    /// 打十轮请求。统计那路读本地文件无所谓，额度这路不行。
    func refreshBalanceIfStale() {
        if let last = Self.balanceAttemptedAt, Date().timeIntervalSince(last) < balanceInterval {
            return
        }
        refreshBalance()
    }

    /// 立刻查一次（手动点刷新按钮走这条）
    func refreshBalance() {
        guard !isBalanceLoading else { return }
        isBalanceLoading = true
        Self.balanceAttemptedAt = Date()

        let balanceService = self.balanceService

        // 与 refresh() 同样的理由用 [self] 而非 [weak self]：面板关闭时若 self
        // 已释放，isBalanceLoading 会永远停在 true，之后再也查不动额度。
        Task.detached(priority: .utility) { [self] in
            let fetched = balanceService.fetch()
            await MainActor.run {
                // 取失败时**保留上一次的好结果**，不清空。
                // 清了会让整条区域消失、窗口高度当场跳一下；留着旧值加上那个
                // 明显偏旧的时间戳，反而如实反映了"没能刷上"这件事。
                if let fetched {
                    self.balance = fetched
                    StatsViewModel.cachedBalance = fetched
                }
                self.isBalanceLoading = false
            }
        }
    }
}
