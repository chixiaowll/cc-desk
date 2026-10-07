// 生成 DMG 窗口背景：左边放 App、右边放「应用程序」，中间箭头，下方安装提示。
// 用法：swift scripts/dmg-background.swift <输出.png> <倍率 1|2>
// 坐标与 dmg.sh 里 Finder 的图标位置一致（窗口 640×400，图标中心 (170, 180) 与 (470, 180)）。
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(2)
}
let width = 640.0, height = 400.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// 以左上角为原点，与 Finder 的图标坐标一致。
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// 背景：暖白到浅米色的竖向渐变（与 App 图标的米白底呼应）。
let gradient = NSGradient(colors: [color(0xFBF8F3), color(0xF1ECE4)])!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

// 箭头：两个图标之间，陶土色（App 图标里光标的颜色）。
let arrowY = 180.0
let accent = color(0xD9542B)
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 262, y: arrowY))
shaft.line(to: NSPoint(x: 366, y: arrowY))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
accent.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 384, y: arrowY))
head.line(to: NSPoint(x: 362, y: arrowY - 14))
head.line(to: NSPoint(x: 362, y: arrowY + 14))
head.close()
accent.setFill()
head.fill()

// 文字（翻转坐标系里要让文字正着画）。
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: Double) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: style]
    let string = NSAttributedString(string: text, attributes: attrs)
    let bounds = string.boundingRect(with: NSSize(width: width - 60, height: 200), options: [.usesLineFragmentOrigin])
    ctx.saveGState()
    ctx.translateBy(x: 0, y: centerY + bounds.height / 2)
    ctx.scaleBy(x: 1, y: -1)
    string.draw(with: NSRect(x: 30, y: 0, width: width - 60, height: bounds.height), options: [.usesLineFragmentOrigin])
    ctx.restoreGState()
}

draw("把 CC Desk 拖到右边的 Applications（应用程序）完成安装", size: 15, weight: .semibold, color: color(0x3A332C), centerY: 300)
draw("首次打开如果提示无法验证开发者：到「系统设置 › 隐私与安全性」底部点「仍要打开」",
     size: 11.5, weight: .regular, color: color(0x8A8076), centerY: 334)
draw("（macOS 14 也可以在「应用程序」文件夹里右键 CC Desk → 打开）", size: 11.5, weight: .regular,
     color: color(0x8A8076), centerY: 354)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
