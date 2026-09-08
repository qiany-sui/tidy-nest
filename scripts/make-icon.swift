// 使用原生矢量绘制生成构建图标，不依赖外部素材或图形库。
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("需要指定图标输出路径")
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("无法创建图标绘图上下文")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor(calibratedRed: 0.15, green: 0.29, blue: 0.22, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205).fill()

NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.81, alpha: 1).setStroke()
for offset in [0.0, 80.0, 160.0] {
    let nest = NSBezierPath()
    nest.lineWidth = 36
    nest.lineCapStyle = .round
    nest.move(to: NSPoint(x: 272 + offset * 0.3, y: 458 - offset))
    nest.curve(to: NSPoint(x: 752 - offset * 0.3, y: 458 - offset),
               controlPoint1: NSPoint(x: 338, y: 288 - offset * 0.7),
               controlPoint2: NSPoint(x: 686, y: 288 - offset * 0.7))
    nest.stroke()
}

NSColor(calibratedRed: 0.68, green: 0.83, blue: 0.56, alpha: 1).setFill()
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 466, y: 472))
leaf.curve(to: NSPoint(x: 714, y: 760),
           controlPoint1: NSPoint(x: 430, y: 666),
           controlPoint2: NSPoint(x: 556, y: 756))
leaf.curve(to: NSPoint(x: 466, y: 472),
           controlPoint1: NSPoint(x: 754, y: 573),
           controlPoint2: NSPoint(x: 613, y: 467))
leaf.close()
leaf.fill()

NSColor(calibratedRed: 0.15, green: 0.29, blue: 0.22, alpha: 1).setStroke()
let stem = NSBezierPath()
stem.lineWidth = 19
stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 490, y: 488))
stem.line(to: NSPoint(x: 628, y: 658))
stem.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法编码图标")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
