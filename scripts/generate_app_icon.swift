#!/usr/bin/env swift
import Cocoa
import CoreGraphics

// ==============================================================================
//  MacSW: 原生 macOS HIG 应用图标生成工具 (Master Pro Edition)
//  - 遵循 Apple Human Interface Guidelines (macOS 1024x1024 标准连续曲率 Squircle)
//  - 渲染深色高级钛金/石墨底板 + 悬浮 3D 紫色等轴测立方体 (避免版权且风格契合)
//  - 自动输出 1024x1024 PNG 及全套 Apple .iconset 并编译为 AppIcon.icns
// ==============================================================================

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let scriptDir = scriptURL.deletingLastPathComponent().path
let rootDir = (scriptDir as NSString).deletingLastPathComponent

// Output to the build tree by default; an explicit directory may be supplied.
let resourcesDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
    : "\(rootDir)/build/resources"
let masterPngPath = "\(resourcesDir)/AppIcon_1024.png"
let icnsPath = "\(resourcesDir)/AppIcon.icns"
let tempIconsetDir = "/tmp/MacSW.iconset"

try? fileManager.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true, attributes: nil)

func renderMasterIcon() -> NSImage {
    let size: CGFloat = 1024.0
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext

    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Apple macOS App Icon Squircle Geometry
    // 规范：824x824 基准矩形，居中 (x: 100, y: 100)，连续平滑圆角 185px
    let baseRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.0

    func createSquirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    let squirclePath = createSquirclePath(in: baseRect, radius: cornerRadius)

    // 2. 双层 macOS 系统下沉微阴影 (Apple HIG Depth)
    cg.saveGState()
    // 柔和环境漫反射扩散阴影
    cg.setShadow(offset: CGSize(width: 0, height: -24), blur: 42, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    cg.addPath(squirclePath)
    cg.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.08, alpha: 1.0))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    // 近距离接触阴影
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    cg.addPath(squirclePath)
    cg.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.08, alpha: 1.0))
    cg.fillPath()
    cg.restoreGState()

    // 3. 绘制深色高级基底板 (Dark Titanium & Midnight Obsidian)
    cg.saveGState()
    cg.addPath(squirclePath)
    cg.clip()

    // 深色渐变：深邃石墨黑到午夜炭黑
    let bgColors = [
        CGColor(red: 0.17, green: 0.16, blue: 0.22, alpha: 1.0), // top: #2C2938
        CGColor(red: 0.11, green: 0.10, blue: 0.15, alpha: 1.0), // mid: #1C1A26
        CGColor(red: 0.06, green: 0.05, blue: 0.08, alpha: 1.0)  // bottom: #0F0D14
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.5, 1.0]
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        cg.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }

    // 顶部微妙天光弧度反射 (Subtle curvature ambient sheen)
    let ambientColors = [
        CGColor(red: 0.32, green: 0.28, blue: 0.44, alpha: 0.18),
        CGColor(red: 0.11, green: 0.10, blue: 0.15, alpha: 0.0)
    ] as CFArray
    if let ambientGrad = CGGradient(colorsSpace: colorSpace, colors: ambientColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(ambientGrad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 480), options: [])
    }

    // 4. 立方体背后的环境悬浮紫色辉光 (Ambient Floating Core Glow)
    let glowColors = [
        CGColor(red: 0.70, green: 0.35, blue: 0.96, alpha: 0.24),
        CGColor(red: 0.48, green: 0.18, blue: 0.76, alpha: 0.09),
        CGColor(red: 0.20, green: 0.06, blue: 0.38, alpha: 0.0)
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.45, 1.0]) {
        cg.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: 512, y: 508),
            startRadius: 20,
            endCenter: CGPoint(x: 512, y: 508),
            endRadius: 360,
            options: []
        )
    }

    // 5. 精确 3D 等轴测立方体几何 (Isometric Cube Geometry)
    let cX: CGFloat = 512.0
    let cY: CGFloat = 508.0 // 视觉中心
    let R: CGFloat = 236.0  // 正六边形外接圆半径

    let cos30: CGFloat = cos(CGFloat.pi / 6.0) // 0.866025
    let sin30: CGFloat = sin(CGFloat.pi / 6.0) // 0.5

    // 6 个顶点：严格标准等轴测六边形
    let pCenter      = CGPoint(x: cX, y: cY)
    let pTop         = CGPoint(x: cX, y: cY + R)
    let pTopRight    = CGPoint(x: cX + R * cos30, y: cY + R * sin30)
    let pBottomRight = CGPoint(x: cX + R * cos30, y: cY - R * sin30)
    let pBottom      = CGPoint(x: cX, y: cY - R)
    let pBottomLeft  = CGPoint(x: cX - R * cos30, y: cY - R * sin30)
    let pTopLeft     = CGPoint(x: cX - R * cos30, y: cY + R * sin30)

    // 5.1 立方体地面漫反射投影与紫光反弹 (Ambient Floor Shadow & Bounce Light)
    cg.saveGState()
    let shadowRect = CGRect(x: cX - 220, y: cY - R - 46, width: 440, height: 96)
    let shadowColors = [
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.62),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.28),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    ] as CFArray
    if let shadowGrad = CGGradient(colorsSpace: colorSpace, colors: shadowColors, locations: [0.0, 0.45, 1.0]) {
        cg.saveGState()
        cg.translateBy(x: shadowRect.midX, y: shadowRect.midY)
        cg.scaleBy(x: 1.0, y: 0.26)
        cg.drawRadialGradient(shadowGrad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 240, options: [])
        cg.restoreGState()
    }
    let bounceColors = [
        CGColor(red: 0.65, green: 0.25, blue: 0.95, alpha: 0.25),
        CGColor(red: 0.40, green: 0.10, blue: 0.65, alpha: 0.0)
    ] as CFArray
    if let bounceGrad = CGGradient(colorsSpace: colorSpace, colors: bounceColors, locations: [0.0, 1.0]) {
        cg.saveGState()
        cg.translateBy(x: cX, y: cY - R - 4)
        cg.scaleBy(x: 1.0, y: 0.28)
        cg.drawRadialGradient(bounceGrad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 170, options: [])
        cg.restoreGState()
    }
    cg.restoreGState()

    // 绘制多边形面
    func drawFace(points: [CGPoint], colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint, strokeColor: CGColor?, strokeWidth: CGFloat = 1.5) {
        guard points.count >= 3 else { return }
        let path = CGMutablePath()
        path.move(to: points[0])
        for pt in points.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()

        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
            cg.drawLinearGradient(grad, start: start, end: end, options: [])
        }
        cg.restoreGState()

        if let sc = strokeColor {
            cg.saveGState()
            cg.addPath(path)
            cg.setStrokeColor(sc)
            cg.setLineWidth(strokeWidth)
            cg.setLineJoin(.round)
            cg.strokePath()
            cg.restoreGState()
        }
    }

    // 5.2 左侧面 (背光暗面 - 典雅高饱和宝石紫)
    let leftFacePoints = [pCenter, pTopLeft, pBottomLeft, pBottom]
    let leftFaceColors = [
        CGColor(red: 0.56, green: 0.20, blue: 0.82, alpha: 1.0), // #8F33D1
        CGColor(red: 0.40, green: 0.12, blue: 0.64, alpha: 1.0), // #661FA3
        CGColor(red: 0.30, green: 0.07, blue: 0.50, alpha: 1.0)  // #4D1280
    ]
    drawFace(
        points: leftFacePoints,
        colors: leftFaceColors,
        locations: [0.0, 0.55, 1.0],
        start: pTopLeft,
        end: pBottom,
        strokeColor: CGColor(red: 0.65, green: 0.30, blue: 0.90, alpha: 0.35)
    )

    // 5.3 右侧面 (侧光半受光面 - 鲜明科技紫)
    let rightFacePoints = [pCenter, pTopRight, pBottomRight, pBottom]
    let rightFaceColors = [
        CGColor(red: 0.76, green: 0.32, blue: 0.98, alpha: 1.0), // #C252FA
        CGColor(red: 0.60, green: 0.20, blue: 0.86, alpha: 1.0), // #9933DB
        CGColor(red: 0.46, green: 0.14, blue: 0.70, alpha: 1.0)  // #7524B3
    ]
    drawFace(
        points: rightFacePoints,
        colors: rightFaceColors,
        locations: [0.0, 0.55, 1.0],
        start: pTopRight,
        end: pBottom,
        strokeColor: CGColor(red: 0.85, green: 0.45, blue: 1.0, alpha: 0.35)
    )

    // 5.4 顶面 (主受光面 - 清透高光浅粉紫/丁香紫)
    let topFacePoints = [pCenter, pTopRight, pTop, pTopLeft]
    let topFaceColors = [
        CGColor(red: 0.95, green: 0.75, blue: 1.00, alpha: 1.0), // #F2BFFF
        CGColor(red: 0.86, green: 0.58, blue: 0.98, alpha: 1.0), // #DC94FA
        CGColor(red: 0.78, green: 0.44, blue: 0.95, alpha: 1.0)  // #C770F2
    ]
    drawFace(
        points: topFacePoints,
        colors: topFaceColors,
        locations: [0.0, 0.45, 1.0],
        start: pTop,
        end: pCenter,
        strokeColor: CGColor(red: 1.0, green: 0.88, blue: 1.0, alpha: 0.6)
    )

    // 5.5 精密光泽倒角折线 (Precision Chamfer & Seam Highlights)
    cg.saveGState()
    cg.setLineCap(.round)

    // 左上分界棱线
    let ridgeTopLeft = CGMutablePath()
    ridgeTopLeft.move(to: pCenter)
    ridgeTopLeft.addLine(to: pTopLeft)
    cg.addPath(ridgeTopLeft)
    cg.setStrokeColor(CGColor(red: 1.0, green: 0.90, blue: 1.0, alpha: 0.75))
    cg.setLineWidth(2.2)
    cg.strokePath()

    // 右上分界棱线
    let ridgeTopRight = CGMutablePath()
    ridgeTopRight.move(to: pCenter)
    ridgeTopRight.addLine(to: pTopRight)
    cg.addPath(ridgeTopRight)
    cg.setStrokeColor(CGColor(red: 1.0, green: 0.90, blue: 1.0, alpha: 0.75))
    cg.setLineWidth(2.2)
    cg.strokePath()

    // 中垂分界棱线
    let ridgeCenter = CGMutablePath()
    ridgeCenter.move(to: pCenter)
    ridgeCenter.addLine(to: pBottom)
    cg.addPath(ridgeCenter)
    cg.setStrokeColor(CGColor(red: 0.78, green: 0.38, blue: 0.98, alpha: 0.45))
    cg.setLineWidth(2.0)
    cg.strokePath()

    // 中心汇聚点高光星芒
    let gleamColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95),
        CGColor(red: 0.95, green: 0.80, blue: 1.0, alpha: 0.45),
        CGColor(red: 0.85, green: 0.60, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let gleamGrad = CGGradient(colorsSpace: colorSpace, colors: gleamColors, locations: [0.0, 0.35, 1.0]) {
        cg.drawRadialGradient(
            gleamGrad,
            startCenter: pCenter,
            startRadius: 0,
            endCenter: pCenter,
            endRadius: 22,
            options: []
        )
    }
    cg.restoreGState()

    // 6. Apple HIG Squircle 外圈天光微边缘 (Subtle Inner Rim Light)
    cg.saveGState()
    let rimColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.02)
    ] as CFArray
    if let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 0.4, 1.0]) {
        cg.addPath(squirclePath)
        cg.setLineWidth(2.0)
        cg.replacePathWithStrokedPath()
        cg.clip()
        cg.drawLinearGradient(rimGrad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }
    cg.restoreGState()

    cg.restoreGState() // unclip squircle
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}

print("==> [MacSW] Rendering the 1024x1024 native Apple HIG icon...")
let masterImage = renderMasterIcon()

// 1. 导出 1024x1024 PNG 主图
if let tiff = masterImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: masterPngPath))
        print("==> [SUCCESS] Exported master image: \(masterPngPath)")
    }
}

// 2. 生成规范的 Apple .iconset 尺寸
try? fileManager.createDirectory(atPath: tempIconsetDir, withIntermediateDirectories: true, attributes: nil)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    let resizedRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: resizedRep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    masterImage.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1.0)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    
    if let png = resizedRep.representation(using: .png, properties: [:]) {
        let filePath = "\(tempIconsetDir)/\(filename)"
        try? png.write(to: URL(fileURLWithPath: filePath))
    }
}

// 3. 调用系统 iconutil 编译标准 AppIcon.icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", tempIconsetDir, "-o", icnsPath]
do {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
        print("==> [SUCCESS] Compiled the standard macOS icon resource: \(icnsPath)")
    } else {
        print("==> [ERROR] iconutil failed, exit code: \(process.terminationStatus)")
    }
} catch {
    print("==> [ERROR] Could not start iconutil: \(error)")
}

// 清理临时 iconset 缓存
try? fileManager.removeItem(atPath: tempIconsetDir)
print("==> [FINISH] Icon generation complete!")
