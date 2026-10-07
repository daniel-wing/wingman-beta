// Renders Resources/AppIcon.icns: a "W" made of audio bars on a blue gradient.
// Default style is "floating".
// Run: swift scripts/make-icon.swift [striped|equalizer|mirrored|floating|solid] [preview.png]
import AppKit

let style = CommandLine.arguments.dropFirst().first ?? "floating"
let previewPath = CommandLine.arguments.dropFirst(2).first

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let tile = rect.insetBy(dx: 100, dy: 100)
    NSGradient(colors: [NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1),
                        NSColor(red: 0.05, green: 0.33, blue: 0.86, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185), angle: -90)
    NSColor.white.setFill()

    switch style {
    case "equalizer", "mirrored", "floating":
        // Audio bars arranged to spell a W:
        //  equalizer — bars stand on a baseline, tops trace the W
        //  mirrored  — bars centered like a waveform, tops trace the W
        //  floating  — equal bars riding the W's path, tops and bottoms trace it
        let count = 11
        let area = tile.insetBy(dx: 150, dy: 190)
        let pitch = area.width / CGFloat(count)
        let barWidth = pitch * 0.66
        func w(_ t: CGFloat) -> CGFloat {      // t in 0…1 → 0…1 along a W outline
            let points: [(CGFloat, CGFloat)] = [(0, 1), (0.25, 0.22), (0.5, 0.78), (0.75, 0.22), (1, 1)]
            for i in 1..<points.count where t <= points[i].0 {
                let (x0, y0) = points[i - 1], (x1, y1) = points[i]
                return y0 + (y1 - y0) * (t - x0) / (x1 - x0)
            }
            return 1
        }
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = area.minX + CGFloat(i) * pitch + (pitch - barWidth) / 2
            let bar: NSRect
            switch style {
            case "mirrored":
                let h = max(area.height * w(t), barWidth)
                bar = NSRect(x: x, y: area.midY - h / 2, width: barWidth, height: h)
            case "floating":
                let h = area.height * 0.42
                let center = area.minY + h / 2 + (area.height - h) * (w(t) - 0.22) / 0.78
                bar = NSRect(x: x, y: center - h / 2, width: barWidth, height: h)
            default:
                let h = max(area.height * w(t), barWidth)
                bar = NSRect(x: x, y: area.minY, width: barWidth, height: h)
            }
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    default:
        // A W drawn as one thick zigzag stroke, cut into vertical audio bars
        // (or left solid).
        let area = tile.insetBy(dx: 170, dy: 215)
        let points: [(CGFloat, CGFloat)] = [(0, 1), (0.25, 0), (0.5, 0.72), (0.75, 0), (1, 1)]
        let stroke = CGMutablePath()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: area.minX + p.0 * area.width, y: area.minY + p.1 * area.height)
            i == 0 ? stroke.move(to: pt) : stroke.addLine(to: pt)
        }
        let shape = stroke.copy(strokingWithWidth: 125, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let box = shape.boundingBoxOfPath
        let ctx = NSGraphicsContext.current!.cgContext
        if style == "solid" {
            ctx.addPath(shape)
            ctx.fillPath()
            return true
        }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let pitch: CGFloat = 50, bar: CGFloat = 32
        var x = box.minX + 4
        while x < box.maxX {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: box.minY - 20, width: bar, height: box.height + 40),
                               cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
            x += pitch
        }
        ctx.fillPath()
        ctx.restoreGState()
    }
    return true
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if let previewPath {
    try png(512).write(to: URL(fileURLWithPath: previewPath))
    print("Wrote \(previewPath)")
    exit(0)
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns (\(style))" : "iconutil failed")
