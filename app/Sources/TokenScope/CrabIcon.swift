import AppKit

/// 菜单栏小螃蟹图标：直接使用 `CrabFrames.swift` 里的 Clawd 像素动画帧。
///
/// 帧数据与渲染方式都照抄 https://github.com/m1ckc3s/claude-status-bar
/// （MIT）：20 帧全彩像素画，静止态就是第 0 帧 —— 螃蟹不爬的时候原地停住，
/// 与上游 `restingIcon` 的行为一致。帧率也沿用上游实测值 12.5 FPS
/// （见 RobotMonitor.animationInterval，匹配源 GIF 的 0.08s 帧延迟）。
///
/// 配色不做任何改动：Clawd 本身就是橙黄色系，与原 ⚡ 的黄色同一路，
/// 且全彩在深浅两种菜单栏上都立得住 —— 上游的 template 单色适配
/// （CrabRender.swift 的 adaptiveCrabFrame）是给 System 模式准备的，
/// 这里用不上。
enum CrabIcon {

    /// 状态栏上的显示高度（pt）。宽度按帧的宽高比展开（51×36 → 21.25×15）。
    ///
    /// 源位图 36px 高、螃蟹顶天立地撑满包围盒，按菜单栏满高 18pt 画会比
    /// 系统图标显得壮一圈 —— 那些图标的花纹本身自带内边距。15pt（≈17%）
    /// 是「缩到和邻居同视觉重量」的实测值，嫌大嫌小改这一个数就行。
    private static let height: CGFloat = 15

    /// 静止帧：螃蟹原地停住（上游 restingIcon 用 frame 0）
    static let idle: NSImage = render(frames[0])

    /// 忙碌动画的 20 帧
    static let busyFrames: [NSImage] = frames.map(render)

    static var busyFrameCount: Int { busyFrames.count }

    /// base64 PNG → NSImage。解码失败的帧静默丢弃（compactMap），
    /// 数据是编译进二进制的常量，坏了会在帧数断言里暴露。
    private static let frames: [NSImage] = clawdCrabFramePNGs.compactMap {
        Data(base64Encoded: $0).flatMap { NSImage(data: $0) }
    }

    /// 高度固定 18pt、宽度等比的位图。直接以 cgImage 为底层表示并指定 pt
    /// 尺寸：源位图 51×36，18pt 高的显示尺寸正好落在 2x 像素密度上，
    /// Retina 菜单栏下是逐像素清晰的。
    private static func render(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let ratio = height / CGFloat(cg.height)
        return NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) * ratio, height: height)
        )
    }
}
