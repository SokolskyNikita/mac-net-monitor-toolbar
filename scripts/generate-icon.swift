#!/usr/bin/env swift
import AppKit

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("images", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                            xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.20, alpha: 1).setFill()
    path.fill()

    let inset = size * 0.18
    let plot = rect.insetBy(dx: inset, dy: inset)
    let pts: [(CGFloat, CGFloat)] = [
        (0.00, 0.42), (0.18, 0.55), (0.32, 0.28), (0.48, 0.70),
        (0.62, 0.38), (0.78, 0.58), (1.00, 0.46)
    ]
    let line = NSBezierPath()
    line.lineWidth = max(1.5, size * 0.045)
    line.lineJoinStyle = .round
    line.lineCapStyle = .round
    for (i, p) in pts.enumerated() {
        let x = plot.minX + p.0 * plot.width
        let y = plot.minY + p.1 * plot.height
        if i == 0 { line.move(to: NSPoint(x: x, y: y)) }
        else { line.line(to: NSPoint(x: x, y: y)) }
    }
    NSColor(calibratedRed: 0.45, green: 0.82, blue: 1.0, alpha: 1).setStroke()
    line.stroke()

    let chevW = size * 0.14
    let chevH = size * 0.10
    let down = NSBezierPath()
    down.move(to: NSPoint(x: plot.minX, y: plot.minY + chevH))
    down.line(to: NSPoint(x: plot.minX + chevW / 2, y: plot.minY))
    down.line(to: NSPoint(x: plot.minX + chevW, y: plot.minY + chevH))
    down.lineWidth = max(1.5, size * 0.04)
    down.lineCapStyle = .round
    down.lineJoinStyle = .round
    NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.55, alpha: 1).setStroke()
    down.stroke()

    let up = NSBezierPath()
    up.move(to: NSPoint(x: plot.maxX - chevW, y: plot.maxY - chevH))
    up.line(to: NSPoint(x: plot.maxX - chevW / 2, y: plot.maxY))
    up.line(to: NSPoint(x: plot.maxX, y: plot.maxY - chevH))
    up.lineWidth = max(1.5, size * 0.04)
    up.lineCapStyle = .round
    up.lineJoinStyle = .round
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.32, alpha: 1).setStroke()
    up.stroke()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

let master = outDir.appendingPathComponent("AppIcon-1024.png")
try writePNG(drawIcon(size: 1024), to: master)
print("wrote \(master.path)")
