#!/usr/bin/env swift
import AppKit
import Foundation

// An original dock glyph. No Dockset artwork or assets are used.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-icon.swift OUTPUT.iconset\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "OpenDock.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.imageInterpolation = .high
    let background = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888),
                                  xRadius: 210, yRadius: 210)
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.32, green: 0.28, blue: 0.88, alpha: 1),
                                       NSColor(srgbRed: 0.58, green: 0.40, blue: 0.94, alpha: 1),
                                       NSColor(srgbRed: 0.24, green: 0.62, blue: 0.98, alpha: 1)])!
    gradient.draw(in: background, angle: -45)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: 174, y: 554, width: 650, height: 330)).fill()
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: NSRect(x: 160, y: 264, width: 704, height: 278),
                 xRadius: 82, yRadius: 82).fill()
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 203, y: 236, width: 618, height: 38),
                 xRadius: 19, yRadius: 19).fill()
    for (index, y) in [342.0, 382.0, 342.0].enumerated() {
        NSColor.white.withAlphaComponent(index == 1 ? 1 : 0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: 214 + Double(index) * 209, y: y,
                                      width: 178, height: 178),
                     xRadius: 44, yRadius: 44).fill()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OpenDock.Icon", code: 2)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try drawIcon(pixels: size * scale).write(to: destination.appendingPathComponent(name), options: .atomic)
    }
}
print("Generated original OpenDock icon: \(destination.path)")
