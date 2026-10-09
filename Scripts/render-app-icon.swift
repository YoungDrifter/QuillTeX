#!/usr/bin/env swift
// Resize the generated feather-and-TeX master into all application assets.
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let master = NSImage(contentsOf: root.appendingPathComponent("docs/icon/quilltex-master.png"))!
func png(_ size: Int) -> Data {
    let b = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: b)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return b.representation(using: .png, properties: [:])!
}
let assetPath = "QuillTeX/App/Assets.xcassets/AppIcon.appiconset"
let assets = root.appendingPathComponent(assetPath)
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("Contents.json"))) as! [String: Any]
for image in json["images"] as! [[String: Any]] {
    guard let file = image["filename"] as? String else { continue }
    let size: Int
    if let value = image["size"] as? String {
        let base = Int(value.split(separator: "x")[0])!
        size = base * ((image["scale"] as? String) == "2x" ? 2 : 1)
    } else {
        size = Int(file.replacingOccurrences(of: "icon_", with: "").replacingOccurrences(of: ".png", with: ""))!
    }
    try png(size).write(to: assets.appendingPathComponent(file))
}
let mark = root.appendingPathComponent("QuillTeX/App/Assets.xcassets/QuillTeXMark.imageset")
try png(128).write(to: mark.appendingPathComponent("QuillTeXMark.png"))
try png(256).write(to: mark.appendingPathComponent("QuillTeXMark@2x.png"))
print("Rendered black-and-white icon: \(root.lastPathComponent)")
