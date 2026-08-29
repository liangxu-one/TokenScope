import SwiftUI

@main
struct TokenScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 这里没有 SwiftUI 场景：真正的界面是 AppDelegate 建的 NSStatusItem +
    // NSPopover（机器人要逐帧换图和实时计时，MenuBarExtra 的 label 不适合，
    // 取舍见 StatusItemController）。Settings 这个空场景只是给 App 协议一个
    // body —— accessory 应用不会因为「没有可见窗口」被系统收走，进程由
    // 状态项维持。
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
