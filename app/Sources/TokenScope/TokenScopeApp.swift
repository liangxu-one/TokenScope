import SwiftUI

// 这里是纯 AppKit 应用：入口在 main.swift（`NSApplication` + AppDelegate）。
//
// 早先这里是一个 `@main struct TokenScopeApp: App`，body 用
// `Settings { EmptyView() }` 给协议占位 —— 那会在每次启动时弹出一个
// 空白的「TokenScope Settings」窗口（本应用是 accessory，没有别的场景，
// SwiftUI 把它当成了唯一窗口）。去掉 App 结构后，进程里只剩状态项，
// 不会再出现任何意外的窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 机器人监控是进程级的（弹窗关着也得继续轮询），跟状态项一起在这里
        // 起起来；两者各自持有，互不依赖生命周期。开关关着就不起 ——
        // 「不打开」要关得干干净净，0.5 秒一次的轮询也不该空转
        if RobotMonitor.isEnabled {
            RobotMonitor.shared.start()
        }
        statusItemController = StatusItemController(robot: .shared)
    }
}
