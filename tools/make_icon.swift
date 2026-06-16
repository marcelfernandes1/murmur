import AppKit

// Renders the Murmur app icon: an indigo→violet gradient squircle with a subtle
// top sheen and a centered white waveform (capsule bars matching the app's live
// waveform). Writes PNGs + Contents.json into the AppIcon.appiconset.

let outDir = "Murmur/Support/Assets.xcassets/AppIcon.appiconset"

/// Symmetric equalizer heights (fraction of the body height), centered.
let barHeights: [CGFloat] = [0.30, 0.52, 0.74, 0.92, 0.74, 0.52, 0.30]

func iconPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let P = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: P, height: P)
    NSColor.clear.set()
    canvas.fill()

    // Rounded-rect "squircle" body.
    let margin = P * 0.085
    let body = canvas.insetBy(dx: margin, dy: margin)
    let radius = body.width * 0.2237
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Brand gradient (indigo top → violet bottom).
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.40, green: 0.34, blue: 0.96, alpha: 1),
        ending: NSColor(srgbRed: 0.63, green: 0.26, blue: 0.92, alpha: 1))!
    gradient.draw(in: squircle, angle: -90)

    // Subtle top sheen for depth, clipped to the body.
    NSGraphicsContext.saveGraphicsState()
    squircle.setClip()
    let sheenRect = NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
    let sheen = NSGradient(
        starting: NSColor(white: 1, alpha: 0.0),
        ending: NSColor(white: 1, alpha: 0.16))!
    sheen.draw(in: sheenRect, angle: 90) // brighter toward the top
    NSGraphicsContext.restoreGraphicsState()

    // Centered white waveform bars.
    let count = barHeights.count
    let barW = body.width * 0.066
    let gap = body.width * 0.050
    let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
    var x = body.midX - totalW / 2
    NSColor.white.setFill()
    for h in barHeights {
        let barH = max(barW, body.height * 0.62 * h)
        let rect = NSRect(x: x, y: body.midY - barH / 2, width: barW, height: barH)
        NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
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
