import AppKit

// 进程入口。**刻意不用 SwiftUI 的 `@main App` + `Settings` 空场景。**
//
// 本应用是纯菜单栏 accessory：唯一的界面是 `NSStatusItem` + `NSPopover`
// （见 StatusItemController）。而 SwiftUI 的 App 协议必须给一个 Scene，
// 早先拿 `Settings { EmptyView() }` 占位 —— 结果启动时它会把这个场景
// 当成唯一窗口弹出来：一个 900×450、标题「TokenScope Settings」的空白
// 窗口（2026-10-22 实测，每次启动都出现，位置常常在屏幕外所以长期没人
// 发现）。想点「设置」也没内容可看，纯粹是干扰。
//
// 改用 AppKit 启动后，进程里只有状态项和弹窗，没有任何 SwiftUI 场景。
let app = NSApplication.shared
// 进 run 之前就定成 accessory：否则进程会先以普通应用身份闪一下 Dock 图标
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
