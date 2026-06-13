import AppKit

// Renders the Murmur app icon (gradient squircle + white waveform) at every
// size macOS needs, writing PNGs + Contents.json into the AppIcon.appiconset.

let outDir = "Murmur/Support/Assets.xcassets/AppIcon.appiconset"

func tintedWaveform(point: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: point, weight: .semibold)
    guard let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    let out = NSImage(size: base.size)
    out.lockFocus()
    NSColor.white.set()
    let rect = NSRect(origin: .zero, size: base.size)
    base.draw(in: rect)
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func iconPNG(pixels: Int) -> Data {
    let glyph = tintedWaveform(point: CGFloat(pixels) * 0.42)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.set()
    canvas.fill()

    let margin = CGFloat(pixels) * 0.085
    let body = canvas.insetBy(dx: margin, dy: margin)
    let radius = body.width * 0.2237
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.36, green: 0.30, blue: 0.93, alpha: 1),
        ending: NSColor(srgbRed: 0.64, green: 0.27, blue: 0.91, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    if let glyph {
        let drawRect = NSRect(
            x: (CGFloat(pixels) - glyph.size.width) / 2,
            y: (CGFloat(pixels) - glyph.size.height) / 2,
            width: glyph.size.width, height: glyph.size.height)
        glyph.draw(in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct Entry { let size: Int; let scale: Int; let file: String }
let entries: [Entry] = [
    .init(size: 16, scale: 1, file: "icon_16.png"),
    .init(size: 16, scale: 2, file: "icon_16@2x.png"),
    .init(size: 32, scale: 1, file: "icon_32.png"),
    .init(size: 32, scale: 2, file: "icon_32@2x.png"),
    .init(size: 128, scale: 1, file: "icon_128.png"),
    .init(size: 128, scale: 2, file: "icon_128@2x.png"),
    .init(size: 256, scale: 1, file: "icon_256.png"),
    .init(size: 256, scale: 2, file: "icon_256@2x.png"),
    .init(size: 512, scale: 1, file: "icon_512.png"),
    .init(size: 512, scale: 2, file: "icon_512@2x.png"),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for e in entries {
    let pixels = e.size * e.scale
    let data = iconPNG(pixels: pixels)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(e.file)"))
}

let images = entries.map {
    "    { \"size\" : \"\($0.size)x\($0.size)\", \"idiom\" : \"mac\", \"filename\" : \"\($0.file)\", \"scale\" : \"\($0.scale)x\" }"
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icon PNGs + Contents.json to \(outDir)")
