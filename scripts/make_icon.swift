#!/usr/bin/env swift
// Generates AppIcon.icns: a warm sun glyph on a dark rounded-rect, macOS-style margins.
// Usage: swift scripts/make_icon.swift Support/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // macOS icon grid: the tile is inset ~10% with ~22.5% corner radius.
    let inset = s * 0.10
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // Sun glyph from SF Symbols, tinted warm yellow.
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.52, weight: .medium)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.25, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyphSize = symbol.size
        let scale = (tile.width * 0.62) / max(glyphSize.width, glyphSize.height)
        let w = glyphSize.width * scale, h = glyphSize.height * scale
        let rect = NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h)
        symbol.draw(in: rect)
    }

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LGforMac.iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for mult in [1, 2] {
        let px = base * mult
        let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(drawIcon(size: px), pixels: px).write(to: tmp.appendingPathComponent(name))
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tmp.path, "-o", output]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print(proc.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
exit(proc.terminationStatus)
