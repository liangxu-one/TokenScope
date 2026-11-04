import Foundation

/// 代理写出的实时状态，内容对应 `proxy/ai_status.json`。
///
/// 字段与 `http_proxy.py` 里 `LiveStatus._write_locked()` 的 payload 一一对应：
/// epoch 浮点时间戳是两个进程共享的「现在」，不涉及时区与格式化 ——
/// 这是它与 jsonl 统计里字符串时间戳（`2026-08-29 12:00:00`）刻意的不同。
struct LiveStatusSnapshot: Codable {
    /// Equatable：RobotMonitor 轮询时用「值没变就不发 objectWillChange」
    /// 压掉面板的空转重绘（2026-08-29 卡顿修复的一半）。
    struct Request: Codable, Equatable {
        let provider: String
        let model: String
        let stream: Bool
        /// 请求开始的 epoch 秒
        let started: Double
    }

    /// 代理进程号。app 侧目前不消费，留作排查（对着 `ps` 看代理还在不在）。
    let pid: Int
    /// 正在转发中的请求数
    let inFlight: Int
    /// 当前回合的起点。回合语义见代理侧 `LiveStatus` 的注释。
    let turnStart: Double?
    /// 最近一次活动（请求开始、chunk 到达、心跳）的 epoch 秒
    let lastActivity: Double?
    /// 这份文件写入的时刻。stale 判定的依据
    let updatedAt: Double
    let requests: [Request]

    enum CodingKeys: String, CodingKey {
        case pid
        case inFlight = "in_flight"
        case turnStart = "turn_start"
        case lastActivity = "last_activity"
        case updatedAt = "updated_at"
        case requests
    }
}

// MARK: - 忙碌判定

/// 判定语义的常量。
///
/// ⚠️ 与 `proxy/http_proxy.py` 的 `LIVE_STATUS_QUIET_SECONDS` **故意不同**（3 vs 15），
/// 两者管的不是同一件事，别再「对齐」它们：
/// - 代理侧 15 秒：判定「这一轮算不算延续」，决定 `turn_start` 要不要重置成新回合；
/// - app 侧 3 秒：只管 UI 尾巴 —— 响应结束后最多再显示几秒的爬行与计时。
/// 2026-11-04 用户要求「话说完就停」：15 秒尾巴太长，3 秒内没有新请求就停。
enum LiveStatusSemantics {
    /// UI 尾巴。最后一次活动过去没超过它，机器人继续爬、计时继续走；
    /// 超过就当作「这一轮已经说完」，螃蟹停住、菜单栏数字清空。
    /// 刻意比代理侧的回合窗口短得多：中间工具执行的间隙由代理去算，
    /// UI 不陪它等满 15 秒（代价是 10 秒后再来的请求会让数字从中断处「复活」）。
    static let quietSeconds: TimeInterval = 3

    /// 文件过旧即视为代理失联。与 quietSeconds 无关，配对的是代理的
    /// 5 秒心跳（见 `LIVE_STATUS_HEARTBEAT_SECONDS`）：忙碌期间文件年龄正常
    /// 不会超过心跳间隔，超过 20 秒还带着 in_flight > 0，只能是代理崩了 ——
    /// 机器人必须睡，不能永远「忙」下去。
    static let staleSeconds: TimeInterval = 20
}

extension LiveStatusSnapshot {

    /// 机器人此刻是否该处于「工作中」。
    ///
    /// 两种来源：真有请求在途（`in_flight > 0`），或刚安静下来没超过安静窗口。
    /// stale 优先：文件过旧一律判空闲，哪怕里面还写着在途 —— 代理可能已经没了。
    func isBusy(now: TimeInterval) -> Bool {
        guard now - updatedAt <= LiveStatusSemantics.staleSeconds else { return false }
        if inFlight > 0 { return true }
        guard let lastActivity else { return false }
        return now - lastActivity < LiveStatusSemantics.quietSeconds
    }
}

// MARK: - 读取

/// 每 0.5 秒读一次 `ai_status.json` 的轻量服务。
///
/// 只读，绝不写入 —— 与 `AiStatsService` 同一条约定（写入方只有代理）。
/// 文件由代理原子写（tmp + rename），不存在读到半行 JSON 的问题；
/// 读到的是上一次的内容也只是状态晚半秒，无需任何补救。
final class LiveStatusService {

    private let filePath: String

    /// `directory` 仅供测试注入；生产走与统计文件相同的目录推算。
    init(directory: String? = nil) {
        let dir = directory ?? AiStatsService.resolveStatsDirectory()
        filePath = dir + "/ai_status.json"
    }

    /// 读当前状态。文件不存在（代理没在跑）或解码失败（版本错位等）都返回
    /// nil，由上层按「空闲」处理 —— 状态文件缺失不是错误，是常态之一。
    func read() -> LiveStatusSnapshot? {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return nil
        }
        return try? JSONDecoder().decode(LiveStatusSnapshot.self, from: data)
    }
}
