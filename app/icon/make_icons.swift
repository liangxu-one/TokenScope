#!/usr/bin/env swift
//
// 图标生成器：用 Core Graphics 绘制多套方案，导出 1024×1024 PNG 预览。
// 确定方案后由 make_icns.sh 生成 .icns。
//
// 用法： swift make_icons.swift <输出目录>
//

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - 通用工具

func makeContext() -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func save(_ ctx: CGContext, as name: String) {
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: "\(outputDir)/\(name).png")
    try? data.write(to: url)
    print("  ✓ \(name).png")
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// macOS 风格圆角矩形背景 + 渐变
func drawSquircleBackground(_ ctx: CGContext, colors: [CGColor], inset: CGFloat = 0) {
    // macOS Big Sur 图标规范：内容占约 82%，圆角半径约为边长的 22.4%
    let margin = size * 0.09 + inset
    let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.2237

    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: colors as CFArray,
        locations: colors.count == 2 ? [0, 1] : [0, 0.5, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    // 顶部高光，增加立体感
    let highlight = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: []
    )
    ctx.restoreGState()
}

// MARK: - 方案 A：仪表盘

func drawGauge() {
    let ctx = makeContext()
    drawSquircleBackground(ctx, colors: [rgb(58, 82, 178), rgb(28, 38, 96)])

    let center = CGPoint(x: size / 2, y: size / 2 - size * 0.03)
    let radius = size * 0.27
    let lineWidth = size * 0.055

    // 表盘底环（270° 开口向下）
    let startAngle: CGFloat = .pi * 0.75
    let endAngle: CGFloat = .pi * 2.25

    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()

    // 进度弧：约 78%（对应缓存命中率）
    let progress: CGFloat = 0.78
    ctx.setStrokeColor(rgb(94, 226, 168))
    ctx.addArc(
        center: center, radius: radius,
        startAngle: startAngle,
        endAngle: startAngle + (endAngle - startAngle) * progress,
        clockwise: false
    )
    ctx.strokePath()

    // 指针
    let needleAngle = startAngle + (endAngle - startAngle) * progress
    ctx.setLineWidth(size * 0.028)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(
        x: center.x + cos(needleAngle) * radius * 0.72,
        y: center.y + sin(needleAngle) * radius * 0.72
    ))
    ctx.strokePath()

    // 中心轴
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(
        x: center.x - size * 0.035, y: center.y - size * 0.035,
        width: size * 0.07, height: size * 0.07
    ))
    ctx.setFillColor(rgb(58, 82, 178))
    ctx.fillEllipse(in: CGRect(
        x: center.x - size * 0.016, y: center.y - size * 0.016,
        width: size * 0.032, height: size * 0.032
    ))

    save(ctx, as: "icon_A_gauge")
}

// MARK: - 方案 B：闪电 + 柱状图

func drawBoltBars() {
    let ctx = makeContext()
    drawSquircleBackground(ctx, colors: [rgb(46, 52, 132), rgb(88, 44, 152), rgb(28, 30, 78)])

    // 柱状图：底部四根，高度递增
    let barCount = 4
    let barWidth = size * 0.088
    let gap = size * 0.042
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    let startX = (size - totalWidth) / 2
    let baseY = size * 0.245
    let heights: [CGFloat] = [0.13, 0.2, 0.29, 0.4]
    let barColors = [
        rgb(120, 190, 255, 0.55),
        rgb(120, 210, 255, 0.68),
        rgb(110, 230, 220, 0.82),
        rgb(100, 240, 180, 0.95),
    ]

    for i in 0..<barCount {
        let h = size * heights[i]
        let rect = CGRect(
            x: startX + CGFloat(i) * (barWidth + gap),
            y: baseY, width: barWidth, height: h
        )
        ctx.setFillColor(barColors[i])
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: barWidth * 0.3, cornerHeight: barWidth * 0.3,
            transform: nil
        ))
        ctx.fillPath()
    }

    // 闪电，压在柱状图之上
    let bolt = CGMutablePath()
    let cx = size * 0.5
    let cy = size * 0.62
    let s = size * 0.30
    bolt.move(to: CGPoint(x: cx + s * 0.16, y: cy + s * 0.82))
    bolt.addLine(to: CGPoint(x: cx - s * 0.46, y: cy + s * 0.02))
    bolt.addLine(to: CGPoint(x: cx - s * 0.02, y: cy + s * 0.02))
    bolt.addLine(to: CGPoint(x: cx - s * 0.16, y: cy - s * 0.78))
    bolt.addLine(to: CGPoint(x: cx + s * 0.48, y: cy + s * 0.06))
    bolt.addLine(to: CGPoint(x: cx + s * 0.04, y: cy + s * 0.06))
    bolt.closeSubpath()

    // 闪电外发光
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.05, color: rgb(255, 214, 92, 0.75))
    ctx.setFillColor(rgb(255, 206, 74))
    ctx.addPath(bolt)
    ctx.fillPath()
    ctx.restoreGState()

    save(ctx, as: "icon_B_bolt_bars")
}

// MARK: - 方案 C：环形命中率

func drawRing() {
    let ctx = makeContext()
    drawSquircleBackground(ctx, colors: [rgb(24, 30, 54), rgb(14, 18, 34)])

    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = size * 0.255
    let lineWidth = size * 0.075

    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    // 底环
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // 命中率弧：从 12 点顺时针 80%
    let start: CGFloat = .pi / 2
    let sweep: CGFloat = .pi * 2 * 0.8

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.035, color: rgb(94, 226, 168, 0.6))
    ctx.setStrokeColor(rgb(94, 226, 168))
    ctx.addArc(center: center, radius: radius,
               startAngle: start, endAngle: start - sweep, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // 中心闪电
    let bolt = CGMutablePath()
    let s = size * 0.135
    bolt.move(to: CGPoint(x: center.x + s * 0.16, y: center.y + s * 0.9))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.05))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.04, y: center.y - s * 0.05))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.18, y: center.y - s * 0.9))
    bolt.addLine(to: CGPoint(x: center.x + s * 0.5, y: center.y + s * 0.02))
    bolt.addLine(to: CGPoint(x: center.x + s * 0.04, y: center.y + s * 0.02))
    bolt.closeSubpath()

    ctx.setFillColor(rgb(255, 210, 80))
    ctx.addPath(bolt)
    ctx.fillPath()

    save(ctx, as: "icon_C_ring")
}

// MARK: - 方案 D：望远镜/示波（呼应 Scope）

func drawScope() {
    let ctx = makeContext()
    drawSquircleBackground(ctx, colors: [rgb(20, 32, 60), rgb(10, 16, 32)])

    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = size * 0.275

    // 镜筒圆形
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    ))
    ctx.clip()

    // 内部深色背景
    ctx.setFillColor(rgb(8, 14, 28))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // 网格线
    ctx.setLineWidth(size * 0.004)
    ctx.setStrokeColor(rgb(80, 220, 190, 0.22))
    let gridStep = radius / 2.5
    var offset = -radius
    while offset <= radius {
        ctx.move(to: CGPoint(x: center.x + offset, y: center.y - radius))
        ctx.addLine(to: CGPoint(x: center.x + offset, y: center.y + radius))
        ctx.move(to: CGPoint(x: center.x - radius, y: center.y + offset))
        ctx.addLine(to: CGPoint(x: center.x + radius, y: center.y + offset))
        offset += gridStep
    }
    ctx.strokePath()

    // 波形曲线（token 消耗走势）
    ctx.setLineWidth(size * 0.022)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.03, color: rgb(94, 240, 190, 0.85))
    ctx.setStrokeColor(rgb(94, 240, 190))

    let points: [(CGFloat, CGFloat)] = [
        (-1.0, -0.28), (-0.66, -0.05), (-0.38, -0.42),
        (-0.05, 0.30), (0.28, -0.10), (0.60, 0.52), (1.0, 0.14),
    ]
    for (i, p) in points.enumerated() {
        let pt = CGPoint(x: center.x + p.0 * radius * 0.88, y: center.y + p.1 * radius * 0.72)
        if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()

    // 镜筒边框
    ctx.setLineWidth(size * 0.042)
    ctx.setStrokeColor(rgb(150, 175, 220, 0.9))
    ctx.addEllipse(in: CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    ))
    ctx.strokePath()

    // 高光弧
    ctx.setLineWidth(size * 0.016)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
    ctx.addArc(center: center, radius: radius,
               startAngle: .pi * 0.62, endAngle: .pi * 0.95, clockwise: false)
    ctx.strokePath()

    save(ctx, as: "icon_D_scope")
}

// MARK: - 方案 E：极简 T + 数据条

func drawMinimalT() {
    let ctx = makeContext()
    drawSquircleBackground(ctx, colors: [rgb(38, 44, 62), rgb(18, 20, 30)])

    // 大写 T 字形
    let cx = size / 2
    let topY = size * 0.68
    let barWidth = size * 0.30
    let thickness = size * 0.062

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    // 横
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: cx - barWidth, y: topY, width: barWidth * 2, height: thickness),
        cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil
    ))
    ctx.fillPath()
    // 竖
    ctx.addPath(CGPath(
        roundedRect: CGRect(
            x: cx - thickness / 2, y: size * 0.36,
            width: thickness, height: topY - size * 0.36 + thickness
        ),
        cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil
    ))
    ctx.fillPath()

    // 底部三色数据条：新增 / 缓存 / 输出
    let barH = size * 0.038
    let barY = size * 0.265
    let totalW = size * 0.44
    let segs: [(CGFloat, CGColor)] = [
        (0.30, rgb(88, 160, 255)),
        (0.48, rgb(80, 226, 168)),
        (0.22, rgb(186, 130, 255)),
    ]
    var x = cx - totalW / 2
    for (frac, color) in segs {
        let w = totalW * frac
        ctx.setFillColor(color)
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: x, y: barY, width: w - size * 0.008, height: barH),
            cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil
        ))
        ctx.fillPath()
        x += w
    }

    save(ctx, as: "icon_E_minimal_t")
}

// MARK: - main

print("生成图标方案 → \(outputDir)")
drawGauge()
drawBoltBars()
drawRing()
drawScope()
drawMinimalT()
print("完成。")
