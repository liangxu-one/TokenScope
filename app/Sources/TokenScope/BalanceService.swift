import Foundation

/// 读取各渠道的剩余额度。
///
/// 实现方式是**跑 `python3 balance.py --json` 拿结果**，而不是在 Swift 里重写
/// 各家的余额接口。这是刻意的：
///
/// - 各家字段语义的坑（DeepSeek 金额是字符串、MiniMax 给的是剩余百分比要反转、
///   video 条目要过滤、HTTP 200 也可能是业务失败……）已经在 `balance.py` 里
///   踩过并钉进了 `selftest_usage.py`。同一套逻辑写两遍，迟早有一边算错，
///   而且**错了不会报错**，只会静静显示一个错数字。
/// - README 承诺第三方「写一个函数 + 一行 @provider 装饰器」就能加渠道。
///   若 Swift 有自己的一份实现，加渠道还得再写一遍 Swift，这个承诺就是假的。
///   走子进程则是：谁给 balance.py 加了渠道，菜单栏立刻就能显示。
///
/// 代价是依赖一个 python3 解释器。但代理本身就是 Python，能用这个工具的机器
/// 一定有；找不到时本服务返回 nil，界面把整条余额区**隐藏**（见下面的取舍）。
struct BalanceService {

    /// 硬超时，管的是**整次查询的总时长**，不是每个渠道的预算。
    ///
    /// balance.py 对每个渠道有 15s 网络超时且串行执行，所以两个渠道最坏 30s，
    /// 35 留了点余量。渠道更多又集体超时的话（比如 5 家 × 15s = 75s）会在这里
    /// 被杀掉、这次取不到值 —— 那是刻意的：菜单栏弹窗为一行余额干等一分多钟
    /// 更糟，而上层会保留上次的好结果，只是时间戳偏旧。
    private static let timeout: TimeInterval = 35

    /// python3 候选路径，按优先级。
    ///
    /// ⚠️ 顺序有讲究：Homebrew 的排在 `/usr/bin/python3` **前面**。
    /// `/usr/bin/python3` 是个壳，没装 Command Line Tools 时执行它会弹出
    /// 「安装开发者工具」的系统对话框 —— 一个菜单栏小工具弹这个太唐突。
    /// 有真解释器就先用真的。
    ///
    /// 不用 `/usr/bin/env python3`：GUI 应用从 Finder 启动时拿到的是
    /// LaunchServices 的默认 PATH，而不是你 shell 里的那个，
    /// 于是 conda / pyenv 里的 python3 根本不在搜索范围内，行为还不如写死路径可预测。
    private static let pythonCandidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    /// `balance.py` 所在目录。与统计文件同一个目录（都在仓库的 `proxy/` 下），
    /// 所以直接复用 AiStatsService 的推算逻辑，不再写第二套。
    private let proxyDirectory: String

    init(proxyDirectory: String? = nil) {
        self.proxyDirectory = proxyDirectory ?? AiStatsService.resolveStatsDirectory()
    }

    /// 解释器路径：环境变量优先，其次按候选列表找第一个可执行的。
    private static func pythonPath() -> String? {
        if let custom = ProcessInfo.processInfo.environment["TOKENSCOPE_PYTHON"],
           !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        return pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - 取数

    /// 查一次额度。
    ///
    /// 返回 nil 表示**这台机器上根本没有这个功能**（找不到 balance.py 或
    /// python3、脚本崩了、输出不是合法 JSON），此时界面应整条隐藏 ——
    /// 用户从没配过额度查询，不该被一条报错占掉版面。
    ///
    /// 而单个渠道查失败（缺 key、鉴权失败、网络不通）是**另一回事**：
    /// 那属于可修的配置问题，会作为一条 `.failure` 出现在 items 里正常展示。
    /// 这个区分与 balance.py 里「域名没匹配到就完全不显示、匹配到但缺 key 要提示」
    /// 是同一条原则。
    ///
    /// ⚠️ 会阻塞当前线程数秒（要联网），**只能在后台线程调用**。
    func fetch() -> BalanceSnapshot? {
        let script = (proxyDirectory as NSString).appendingPathComponent("balance.py")
        guard FileManager.default.fileExists(atPath: script) else { return nil }
        guard let python = Self.pythonPath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--json"]
        process.currentDirectoryURL = URL(fileURLWithPath: proxyDirectory)

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }

        // 超时后强杀。子进程被杀 → 管道关闭 → 下面的读取返回，不会卡死。
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: killer)

        // 先读到 EOF 再 waitUntilExit：反过来会在输出超过管道缓冲（64KB）时死锁。
        //
        // stderr 这一路是分开的管道且在这里**还没读**：理论上子进程若往 stderr
        // 灌满 64KB 就会卡住，而我们正阻塞在读 stdout 上，两边互等。
        // balance.py 的 stderr 最多是一份 traceback（几 KB），到不了这个量级；
        // 真兜底的是上面那个超时 —— 到点 terminate 掉子进程，两边管道一起关闭，
        // 这里的读取就会返回。所以最坏情况是等 35 秒，不会永久挂住。
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        // ⚠️ 不按退出码判成败。balance.py 用 exit 2 表示「有渠道查失败」，
        // 但 JSON 仍然是完整有效的，里面就带着那个渠道的错误信息。
        // 按退出码拦掉的话，最该显示出来的失败反而看不到了。
        guard let snapshot = Self.decode(data) else {
            let stderrText = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            if !stderrText.isEmpty {
                print("balance.py 失败: \(stderrText.prefix(500))")
            }
            return nil
        }
        return snapshot
    }

    // MARK: - 解码

    /// 对应 `balance.py --json` 的原始结构。
    ///
    /// 三种 kind 的字段是并集式声明（全部 Optional），不写自定义 `init(from:)` ——
    /// kind 之间字段不重名，用不着真正的 tagged union 解码，映射时按 kind 分派即可。
    private struct Payload: Decodable {
        let updatedAt: String?
        let targets: [String: Target]?

        struct Target: Decodable {
            let kind: String
            // currency
            let isAvailable: Bool?
            let balances: [Balance]?
            // quota
            let windows: [Window]?
            // error
            let error: String?
            let transient: Bool?

            struct Balance: Decodable {
                let currency: String?
                /// 可能为 null：上游给了非法金额，balance.py 会如实传出 null
                /// 而不是伪造成 0（0 会被看成"余额花光了"，比"解析失败"更误导）。
                let total: Double?
            }

            struct Window: Decodable {
                let label: String
                /// **已用**百分比。balance.py 只存这一个方向，剩余量由展示侧算。
                let usedPercent: Double?
                let resetsAt: String?
            }
        }
    }

    private static func decode(_ data: Data) -> BalanceSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }

        // targets 是 JSON 对象，解成 Dictionary 后**键序已经丢了**（配置里的书写
        // 顺序传不过来）。按名字排序，保证每次刷新顺序一致 —— 不然渠道会跳来跳去。
        let items: [BalanceItem] = (payload.targets ?? [:])
            .sorted { $0.key < $1.key }
            .map { BalanceItem(name: $0.key, value: value(of: $0.value)) }

        return BalanceSnapshot(updatedAt: payload.updatedAt ?? "", items: items)
    }

    private static func value(of target: Payload.Target) -> BalanceValue {
        switch target.kind {
        case "currency":
            let amounts = (target.balances ?? []).map {
                MoneyAmount(code: $0.currency ?? "CNY", total: $0.total)
            }
            // 多币种账户会返回多条，各自独立，**绝不能相加**，所以并排显示
            return .currency(amounts: amounts, available: target.isAvailable ?? true)

        case "quota":
            let windows = (target.windows ?? []).map {
                QuotaWindow(label: $0.label, usedPercent: $0.usedPercent ?? 0, resetsAt: $0.resetsAt)
            }
            return .quota(windows: windows)

        case "error":
            // balance.py 的 error 结果一定带 message，?? 只是防御
            return .failure(message: target.error ?? "查询失败",
                            transient: target.transient ?? false)

        default:
            // balance.py 更新后引入了新 kind，而 app 还是旧的。
            //
            // ⚠️ 这里**绝不能**落到「查询失败」那一档：查询其实成功了，
            // 报成失败会让人跑去查网络、查 key、查上游状态，白折腾半天。
            // 如实说明是两边版本对不上，才指得对方向。
            return .failure(message: "不认识的额度类型「\(target.kind)」——"
                            + " app 比 balance.py 旧，重新 build 一下",
                            transient: false)
        }
    }
}

// MARK: - 展示模型

/// 一笔货币余额。`total` 为 nil 表示上游给了解析不出的金额。
///
/// 刻意**不实现 Identifiable**：唯一像 id 的字段是币种代码，而第三方 @provider
/// 完全可能返回两条同币种的记录（分账户、分子账号……）。那样 ForEach 会拿到重复
/// id，SwiftUI 的行为就未定义了。展示侧一律按下标遍历。`QuotaWindow` 同理。
struct MoneyAmount {
    let code: String
    let total: Double?

    /// 货币符号，与 balance.py 的 SYMBOLS 表一致；认不出的币种直接用代码。
    var symbol: String {
        switch code {
        case "CNY": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return code + " "
        }
    }

    var text: String {
        guard let total else { return "解析失败" }
        return symbol + String(format: "%.2f", total)
    }
}

/// 一个时间窗口的套餐用量。同样不实现 Identifiable，理由见 `MoneyAmount`。
struct QuotaWindow {
    let label: String
    /// **已用**百分比（不是剩余）。搞反不会报错，只会把 1% 显示成 99%。
    let usedPercent: Double
    let resetsAt: String?
}

/// 单个渠道的额度。三种形态互斥，对应 balance.py 的 `kind`。
///
/// ⚠️ 别想着把 quota 折算成金额、或给 currency 编一个百分比 ——
/// 前者没有面值，后者没有分母。展示侧必须分开渲染。
enum BalanceValue {
    /// 货币余额：有金额与币种，随消耗单调减少，只有充值才回升，没有重置时间。
    case currency(amounts: [MoneyAmount], available: Bool)
    /// 套餐额度：只有已用百分比与时间窗口，到点自动重置，没有面值。
    case quota(windows: [QuotaWindow])
    /// 这个渠道查失败了。`transient` 为真表示网络类瞬时失败、值得重试。
    case failure(message: String, transient: Bool)
}

struct BalanceItem: Identifiable {
    let name: String
    let value: BalanceValue

    var id: String { name }
}

struct BalanceSnapshot {
    /// balance.py 抓取的时刻（`yyyy-MM-dd HH:mm:ss`）
    let updatedAt: String

    let items: [BalanceItem]

    /// 只取时分，窗口里放不下完整日期
    var shortTime: String {
        let parts = updatedAt.split(separator: " ")
        guard parts.count == 2, parts[1].count >= 5 else { return "" }
        return String(parts[1].prefix(5))
    }
}
