import Foundation
import Combine

/// 机器人状态的唯一持有者：轮询代理的实时状态文件，驱动动画帧与计时文本。
///
/// ⚠️ **必须挂在 App 层（`RobotMonitor.shared`），不能挂在弹窗内容里。**
/// 弹窗每次打开都可能重建内容视图（`StatsViewModel` 的类型属性注释记过这个坑），
/// 而机器人要 7×24 反映代理状态 —— 弹窗关着的时候它也得继续跳。
/// 生命周期是「进程存活期间」，正好是这份状态该有的寿命。
///
/// 与 StatsViewModel 的分工：那边管「今天累计了多少」（30 秒一轮、只开弹窗才跑），
/// 这边管「此刻在不在干活」（0.5 秒一轮、进程全程运行）。两个节奏差 60 倍，
/// 数据源也不同（jsonl vs ai_status.json），不合并成一个模型。
@MainActor
final class RobotMonitor: ObservableObject {

    static let shared = RobotMonitor()

    // MARK: 小螃蟹开关

    private static let storageKey = "menuBarCrabEnabled"

    /// 螃蟹开关，UserDefaults 持久化。
    ///
    /// ⚠️ key **缺失视为开**：小螃蟹是新默认体验，`bool(forKey:)` 对不存在的
    /// key 返回 false，直接用会把「从没碰过设置的人」静默关进闪电模式。
    /// 想用回原来的 ⚡，在状态栏图标上右键取消勾选即可。
    static var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: storageKey) == nil || d.bool(forKey: storageKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    // MARK: 发布给状态栏与横幅的状态

    /// 机器人是否工作中（含回合尾巴，见 `LiveStatusSnapshot.isBusy`）
    @Published private(set) var isBusy = false
    /// 当前动画帧下标（busyFrames 的下标）
    @Published private(set) var frameIndex = 0
    /// 回合计时文本，如 `1m 32s`。nil = 空闲，不显示
    @Published private(set) var elapsedText: String?
    /// 当前在途请求明细，供弹窗横幅展示
    @Published private(set) var activeRequests: [LiveStatusSnapshot.Request] = []

    // MARK: 内部

    private let service = LiveStatusService()
    private var pollTimer: Timer?
    private var animTimer: Timer?

    /// 轮询间隔。状态文件不到 1KB、由代理原子写，读一次的开销可以忽略；
    /// 0.5s 是机器人反应速度与空转之间的折中 —— 再快人眼也分辨不出。
    private static let pollInterval: TimeInterval = 0.5

    /// 动画帧率。12.5 FPS 沿用 claude-status-bar 的实测值 —— 匹配 Clawd
    /// 源 GIF 的 0.08s 帧延迟，爬行节奏就是原版的味道。
    private static let animationInterval: TimeInterval = 1.0 / 12.5

    // MARK: - 生命周期

    /// AppDelegate 启动时调用一次。重复调用是安全的空操作。
    func start() {
        guard pollTimer == nil else { return }
        pollTimer = scheduledTimer(Self.pollInterval) { [weak self] in self?.poll() }
        poll()
    }

    /// 关闭开关时调用：定时器全停，发布状态一并清零。
    ///
    /// ⚠️ 只 invalidate 定时器不够 —— 面板若正开着，横幅还挂着、菜单栏
    /// 计时还显示着，就是「关了开关还在动」的闹鬼现场。清零后
    /// StatusItemController 的订阅会把图标换回 ⚡。
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopAnimating()
        isBusy = false
        frameIndex = 0
        elapsedText = nil
        activeRequests = []
    }

    // MARK: - 轮询

    private func poll() {
        apply(service.read(), now: Date())
    }

    private func apply(_ snapshot: LiveStatusSnapshot?, now: Date) {
        let busy = snapshot?.isBusy(now: now.timeIntervalSince1970) ?? false
        activeRequests = snapshot?.requests ?? []

        if busy != isBusy {
            isBusy = busy
            if busy {
                startAnimating()
            } else {
                stopAnimating()
                frameIndex = 0
            }
        }

        if busy, let turnStart = snapshot?.turnStart {
            // 回合计时从回合起点起算：回合尾巴（最后一个响应已回来、但安静窗口
            // 未过）期间继续走表，下一个请求若在窗口内进来，计时不归零 ——
            // 这正是「同一回合」语义在 UI 上的体现。
            elapsedText = formatTurnElapsed(max(now.timeIntervalSince1970 - turnStart, 0))
        } else {
            elapsedText = nil
        }
    }

    // MARK: - 动画

    private func startAnimating() {
        guard animTimer == nil else { return }
        frameIndex = 0
        animTimer = scheduledTimer(Self.animationInterval) { [weak self] in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % CrabIcon.busyFrameCount
        }
    }

    private func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    /// 建好并挂到主 RunLoop 的 `.common` mode。
    ///
    /// 与 StatsViewModel 的定时器同一个理由：菜单展开/弹窗拖动期间主线程处于
    /// eventTracking mode，默认 mode 的 Timer 会停摆 —— 机器人偏偏要在这种
    /// 时刻继续动（用户正盯着菜单栏看）。
    private func scheduledTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in block() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
