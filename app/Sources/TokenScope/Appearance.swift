import SwiftUI

/// 窗口外观偏好，存在 UserDefaults 里，重启后保留。
///
/// 默认**跟随系统**。菜单栏工具跟随系统是 macOS 的惯例，而且这个界面用的全是
/// 语义色（`windowBackgroundColor` / `.primary` / `.secondary` / 系统强调色），
/// 本来就会跟着系统变 —— 这个枚举只是额外提供「我就要固定用某一种」的余地。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// 给 SwiftUI 环境用。**单靠它切不动菜单栏弹窗**，见下面 nsAppearance。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 直接设到承载弹窗的 `NSWindow` 上；nil = 不干预，继续跟随系统。
    ///
    /// ⚠️ 真正起作用的是这个，不是 `preferredColorScheme`。
    ///
    /// `preferredColorScheme` 是靠 preference 往上冒泡、由**场景**去消费的，
    /// 而 `MenuBarExtra(.menuBarExtraStyle(.window))` 的弹窗不是常规场景，
    /// 它根本不吃这个 preference —— 实测表现是：偏好存下来了、底栏图标也跟着
    /// 变了，窗口背景纹丝不动。（用普通 NSWindow + NSHostingView 做的测试会
    /// 通过，因为那条路径确实消费 preference，别被它骗了。）
    ///
    /// 也不用 `NSApp.appearance`：那是应用级全局，会把菜单栏上那个图标一并
    /// 拽进指定外观，而菜单栏自身跟随系统。设到 window 上影响面刚好。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// UserDefaults 的键。写成常量是为了别在两处各拼一次字符串。
    static let storageKey = "appearancePreference"
}

/// 把外观设到承载当前视图的 `NSWindow` 上。挂成 `.background(...)` 用，本身不画东西。
///
/// 之所以要绕这一圈：SwiftUI 没有「设置宿主窗口外观」的官方修饰符，而
/// `preferredColorScheme` 又切不动菜单栏弹窗（理由见 `nsAppearance`）。
/// 只能拿一个空的 NSView 借到 `view.window` 再动手。
struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        // ⚠️ 必须延到下一轮 runloop：makeNSView 返回时这个 view 还没被插进
        // 视图树，`view.window` 是 nil，当场设就会静默地什么也没做。
        //
        // 每次 update 都重设一遍是刻意的：菜单栏弹窗每次打开都可能是一个新
        // 的 window，只在第一次设会导致关掉再打开就退回系统外观。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // 比 name 而不是比对象（`!==`）。实测 NSAppearance(named:) 返回的是
            // 缓存的同一个实例，所以比对象**当下**也能用 —— 但那是没写进文档的
            // 实现细节，一旦哪天不缓存了，这里就变成每次 update 都重设一遍外观。
            // 比 name 与实例缓存无关，语义也正是「要的外观变了没」。
            if window.appearance?.name != appearance?.name {
                window.appearance = appearance
            }
        }
    }
}
