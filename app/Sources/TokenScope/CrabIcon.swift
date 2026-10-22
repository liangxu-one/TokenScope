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
    ///
    /// 源帧的 0–3 帧左右完全对称（逐像素比对镜像差为 0），所以静止态
    /// 不需要按朝向准备两份。
    static let idle: NSImage = render(frames[0])

    /// 忙碌动画的 20 帧（腿部朝右迈）
    static let busyFrames: [NSImage] = frames.map(render)

    /// 忙碌动画的镜像帧（腿部朝左迈）。菜单栏里「左右来回走」就靠这两组轮换。
    ///
    /// 这组螃蟹是**正面视角**：头、眼、钳都左右对称，镜像后不会变成另一只螃蟹，
    /// 变的只有腿的迈步方向 —— 实测镜像后的序列 ≈ 把走路循环倒放
    /// （镜像第 4 帧与原第 11 帧的像素均差 5/255）。
    static let busyFramesMirrored: [NSImage] = frames.map { mirror(render($0)) }

    static var busyFrameCount: Int { busyFrames.count }

    /// base64 PNG → NSImage。解码失败的帧静默丢弃（compactMap），
    /// 数据是编译进二进制的常量，坏了会在帧数断言里暴露。
    private static let frames: [NSImage] = clawdCrabFramePNGs.compactMap {
        Data(base64Encoded: $0).flatMap { NSImage(data: $0) }
    }

    /// 水平翻转。
    ///
    /// 直接对 CGImage 做变换，而不是用 NSImage 的绘制/翻转 API —— 后者会
    /// 重新采样，像素画边缘会糊出半透明像素（菜单栏底色上很显眼）。
    /// 位图尺寸和 pt 尺寸都保持不变，透明通道也原样带过去。
    private static func mirror(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                data: nil,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }

        ctx.translateBy(x: CGFloat(cg.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let flipped = ctx.makeImage() else { return image }
        return NSImage(cgImage: flipped, size: image.size)
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
