// Canonical fxclip artwork: blue background and the same white link mark.
// Run: swift tools/make_icon.swift (all exports), or --exports-only (Telegram/Android/iOS).
import AppKit

let size: CGFloat = 1024
let blueTop = NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1)
let blueBottom = NSColor(srgbRed: 0.10, green: 0.36, blue: 0.93, alpha: 1)
func drawMark() {
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824 px tile centred in 1024, ~185 px corner radius.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [blueTop, blueBottom])!.draw(in: shape, angle: -90)
    drawMark()
    return true
}

let dir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
if !CommandLine.arguments.contains("--exports-only") {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    try #"{"info":{"version":1,"author":"xcode"}}"#.data(using: .utf8)!
        .write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
}

// A full background suits Telegram's circular crop; no macOS tile padding.
let avatar = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    NSGradient(colors: [blueTop, blueBottom])!
        .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)), angle: -90)
    drawMark()
    return true
}
try writePNG(avatar, pixels: 1024, to: "Telegram/assets/bot-avatar.png")

// Android applies the adaptive mask and background itself, including themed icons.
let mark = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    drawMark()
    return true
}
try writePNG(mark, pixels: 432, to: "android/app/src/main/res/drawable-nodpi/fxclip_link_mark.png")
func hex(_ color: NSColor) -> String {
    String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
           Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
}
try """
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="\(hex(blueTop))" android:endColor="\(hex(blueBottom))" android:angle="270" />
</shape>

""".write(toFile: "android/app/src/main/res/drawable/ic_launcher_background.xml", atomically: true, encoding: .utf8)
// Small surfaces need less padding than an adaptive launcher foreground.
let glyph = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.scaleBy(x: 1.75, y: 1.75)
    context.translateBy(x: -size / 2, y: -size / 2)
    drawMark()
    context.restoreGState()
    return true
}
try writePNG(glyph, pixels: 96, to: "android/app/src/main/res/drawable-nodpi/fxclip_link_glyph.png")
try Data(contentsOf: dir.appendingPathComponent("icon_512x512@2x.png"))
    .write(to: URL(fileURLWithPath: "iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
