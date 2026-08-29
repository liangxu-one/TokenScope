import AppKit
import SwiftUI
import Combine

/// 菜单栏状态项 + 统计弹窗的 AppKit 承载。
///
/// 为什么不用 `MenuBarExtra`：机器人要逐帧换图 + 实时计时文本 + 与菜单栏
/// 观感一致的图文混排，MenuBarExtra 的 label 走 SwiftUI 重求值那条路，
/// 帧率与混排行为都不可控。本仓库「SwiftUI 不够用就下探 AppKit」已有先例
/// （`WindowAppearance`），这次是同一取舍 —— 与 claude-status-bar 的
/// 实现方式（NSStatusItem + NSPopover）同构。
///
/// 弹窗内容仍是原来的 `ContentView`，一行没改它的内部布局：
/// `onAppear`/`onDisappear` 在 popover 显示/关闭时照常触发，
/// 统计轮询的启停时机与 MenuBarExtra 时代一致。
@MainActor
final class StatusItemController: NSObject {

    private let robot: RobotMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private let contextMenu = NSMenu()
    /// 「Clawd 小螃蟹」开关项。留着引用是为了切换后当场改勾选态 ——
    /// 菜单是常驻对象，不重建，勾选态跟着偏好走
    private let crabItem = NSMenuItem()

    /// 关掉小螃蟹后回到的原版图标：SF Symbol 闪电，模板图 + contentTintColor
    /// 染成黄色 —— 与 MenuBarExtra 时代的
    /// `Image(systemName: "bolt.fill").foregroundStyle(.yellow)` 同一观感
    /// （SwiftUI 的 `.yellow` 在 macOS 上就是 systemYellow）。
    private static let boltImage: NSImage = {
        let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "TokenScope")!
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )!
        configured.isTemplate = true
        return configured
    }()

    init(robot: RobotMonitor) {
        self.robot = robot
        super.init()

        contextMenu.addItem(withTitle: "打开统计面板", action: #selector(showPanel), keyEquivalent: "").target = self
        crabItem.title = "Clawd 小螃蟹"
        crabItem.action = #selector(toggleCrab)
        crabItem.target = self
        crabItem.state = RobotMonitor.isEnabled ? .on : .off
        contextMenu.addItem(crabItem)
        contextMenu.addItem(.separator())
        contextMenu.addItem(
            withTitle: "退出 TokenScope",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let hosting = NSHostingController(rootView: ContentView(robot: robot))
        // 弹窗高度随内容变化（忙碌横幅出现/消失）自动调整，
        // 不用手算 contentSize
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        // 点外面自动收起 —— 与 MenuBarExtra(.window) 的行为一致
        popover.behavior = .transient

        guard let button = statusItem.button else { return }
        button.image = CrabIcon.idle
        button.imagePosition = .imageLeading
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        // 左键右键都发给 action，由 currentEvent 区分：右键走菜单（保底退出
        // 入口 —— 万一弹窗弹不出来，应用不能变成杀不掉的进程），左键弹面板
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // 机器人状态 → 图标与计时文本。Combine 的 sink 闭包不在主 actor 上，
        // 用 Task 跳回来；8fps 的节奏下这一次 hop 毫无感知
        robot.$frameIndex
            .sink { [weak self] _ in self?.refreshVisualsOnMain() }
            .store(in: &cancellables)
        robot.$isBusy
            .sink { [weak self] _ in self?.refreshVisualsOnMain() }
            .store(in: &cancellables)
        robot.$elapsedText
            .sink { [weak self] _ in self?.refreshVisualsOnMain() }
            .store(in: &cancellables)
    }

    private func refreshVisualsOnMain() {
        Task { @MainActor [weak self] in
            self?.refreshVisuals()
        }
    }

    // MARK: - 状态栏 visuals

    private func refreshVisuals() {
        guard let button = statusItem.button else { return }
        // 开关关闭：回到原版 ⚡，无计时、无动画。RobotMonitor 已被 toggleCrab
        // 停掉并清零状态，这里只管图标长相
        guard RobotMonitor.isEnabled else {
            button.image = Self.boltImage
            button.contentTintColor = .systemYellow
            button.title = ""
            return
        }
        // 螃蟹是全彩非模板图，不吃 contentTintColor；显式清掉，
        // 防止从闪电切回来时残留的黄色染到什么
        button.contentTintColor = nil
        button.image = robot.isBusy
            ? CrabIcon.busyFrames[robot.frameIndex % CrabIcon.busyFrameCount]
            : CrabIcon.idle
        // 计时文本放图标右侧，空闲时整段清空。前导空格把文本和图标隔开，
        // 系统不会自动加间距
        button.title = robot.elapsedText.map { " \($0)" } ?? ""
    }

    // MARK: - 交互

    @objc private func statusItemClicked(_ sender: Any) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }
        if event.type == .rightMouseUp {
            // 菜单挂上 → 用一次合成点击弹出 → 立刻摘掉，下次左键不受影响
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if popover.isShown {
            // 先判已显示再弹：transient popover 在点状态项本身时不会自己收起，
            // 直接 show 会闪一下旧面板再弹新的
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func showPanel() {
        if let button = statusItem.button, !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// 小螃蟹开关。关 = 完全停（轮询、动画、横幅、计时全没），回到纯统计工具；
    /// 开 = 恢复轮询并立刻按当前状态刷新图标。偏好落 UserDefaults，重启保留。
    @objc private func toggleCrab() {
        let enabled = !RobotMonitor.isEnabled
        RobotMonitor.isEnabled = enabled
        crabItem.state = enabled ? .on : .off
        if enabled {
            robot.start()
        } else {
            robot.stop()
        }
        refreshVisuals()
    }
}
