// Draws the background of the installer disk image: an arrow from where
// Wingman's icon sits to the Applications folder, and one line saying what to
// do. The icon positions are in scripts/dmg-settings.py (window 600 × 400 pt,
// icons centred at x 160 and 440, y 160 from the top; the text stays well
// above the bottom, which Finder's tab bar can cover).
//
//   swift scripts/make-dmg-background.swift Resources/dmg
//   → background.png (1×), background@2x.png (2×), combined into
//     background.tiff with tiffutil by scripts/make-dmg.sh
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = CGSize(width: 600, height: 400)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // A quiet, light background: Finder shows it as is, in light and dark mode.
    NSGradient(starting: NSColor(calibratedWhite: 0.98, alpha: 1), ending: NSColor(calibratedWhite: 0.92, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // The arrow, between the two icons (y 160 from the top = 240 from the bottom).
    let y: CGFloat = 240
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 250, y: y))
    arrow.line(to: NSPoint(x: 340, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let tint = NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.85, alpha: 1)
    tint.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 356, y: y))
    head.line(to: NSPoint(x: 334, y: y + 14))
    head.line(to: NSPoint(x: 334, y: y - 14))
    head.close()
    tint.setFill()
    head.fill()

    // The instruction, centred under the icons.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
        .paragraphStyle: style,
    ]
    let detail: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(calibratedWhite: 0.40, alpha: 1),
        .paragraphStyle: style,
    ]
    NSAttributedString(string: "Drag Wingman to Applications", attributes: title)
        .draw(in: NSRect(x: 0, y: 100, width: size.width, height: 24))
    NSAttributedString(string: "Then open it from Applications. A short guide walks you through the rest.", attributes: detail)
        .draw(in: NSRect(x: 0, y: 76, width: size.width, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try render(scale: 1).write(to: folder.appendingPathComponent("background.png"))
try render(scale: 2).write(to: folder.appendingPathComponent("background@2x.png"))
print("wrote \(folder.path)/background.png and background@2x.png")
