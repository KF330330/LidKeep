#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Native transcription of the approved A35 and M03 SVGs. All coordinates
// below use the originals' top-left origin; no browser or SVG library is used.
enum ExportError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let background = CGColor(srgbRed: 37 / 255, green: 41 / 255, blue: 48 / 255, alpha: 1)
let silver = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
    CGColor(srgbRed: 245 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1),
    CGColor(srgbRed: 213 / 255, green: 220 / 255, blue: 225 / 255, alpha: 1),
    CGColor(srgbRed: 125 / 255, green: 137 / 255, blue: 148 / 255, alpha: 1),
    CGColor(srgbRed: 222 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
] as CFArray, locations: [0, 0.32, 0.57, 1])!

func curve(_ path: CGMutablePath, _ x1: Double, _ y1: Double, _ x2: Double,
           _ y2: Double, _ x: Double, _ y: Double) {
    path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                  control2: CGPoint(x: x2, y: y2))
}

func stroke(_ path: CGPath, on context: CGContext, color: CGColor,
            width: CGFloat, cap: CGLineCap = .round) {
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(cap)
    context.setLineJoin(.round)
    context.strokePath()
}

func drawAppIcon(_ context: CGContext) {
    context.setFillColor(background)
    context.addPath(CGPath(roundedRect: CGRect(x: 8, y: 8, width: 240, height: 240),
                          cornerWidth: 54, cornerHeight: 54, transform: nil))
    context.fillPath()
    func silverStroke(_ path: CGPath) {
        context.saveGState()
        context.addPath(path.copy(strokingWithWidth: 21, lineCap: .butt, lineJoin: .round, miterLimit: 10))
        context.clip()
        context.drawLinearGradient(silver, start: CGPoint(x: 128, y: 81), end: CGPoint(x: 128, y: 175),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    let infinity = CGMutablePath()
    infinity.move(to: CGPoint(x: 128, y: 128))
    curve(infinity, 108, 103, 99, 92, 80, 92)
    curve(infinity, 48, 92, 48, 164, 80, 164)
    curve(infinity, 99, 164, 108, 153, 128, 128)
    curve(infinity, 148, 103, 157, 92, 176, 92)
    curve(infinity, 208, 92, 208, 164, 176, 164)
    curve(infinity, 157, 164, 148, 153, 128, 128)
    infinity.closeSubpath()
    silverStroke(infinity)
    let clearance = CGMutablePath()
    clearance.move(to: CGPoint(x: 115, y: 111.9))
    curve(clearance, 119.5, 117.4, 123.5, 122.5, 128, 128)
    curve(clearance, 132.5, 133.5, 136.5, 138.6, 141, 144.1)
    stroke(clearance, on: context, color: background, width: 28, cap: .butt)
    let bridge = CGMutablePath()
    bridge.move(to: CGPoint(x: 112, y: 108.5))
    curve(bridge, 118, 115.5, 123, 122, 128, 128)
    curve(bridge, 133, 134, 138, 140.5, 144, 147.5)
    silverStroke(bridge)
    let highlight = CGMutablePath()
    highlight.move(to: CGPoint(x: 59, y: 111))
    curve(highlight, 61, 100, 69, 94, 80, 94)
    curve(highlight, 94, 94, 103, 103, 111, 113)
    highlight.move(to: CGPoint(x: 151, y: 107))
    curve(highlight, 160, 97, 167, 94, 176, 94)
    stroke(highlight, on: context, color: CGColor(gray: 1, alpha: 0.36), width: 1.8)
}

func drawStatusIcon(_ context: CGContext) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 12, y: 12))
    curve(path, 9.8, 8.9, 8.5, 7.5, 6.5, 7.5)
    path.addArc(center: CGPoint(x: 6.5, y: 12), radius: 4.5,
                startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
    curve(path, 8.5, 16.5, 9.8, 15.1, 12, 12)
    curve(path, 14.2, 8.9, 15.5, 7.5, 17.5, 7.5)
    path.addArc(center: CGPoint(x: 17.5, y: 12), radius: 4.5,
                startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    curve(path, 15.5, 16.5, 14.2, 15.1, 12, 12)
    path.closeSubpath()
    stroke(path, on: context, color: CGColor(gray: 0, alpha: 1), width: 2)
}

func png(side: Int, coordinateSize: CGFloat, draw: (CGContext) -> Void) throws -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ExportError.failed("Cannot create \(side)px bitmap context")
    }
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: CGFloat(side) / coordinateSize, y: -CGFloat(side) / coordinateSize)
    draw(context)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
          !data.isEmpty else { throw ExportError.failed("PNG export failed") }
    return data
}

func statusPDF() throws -> Data {
    let buffer = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    let info = [kCGPDFContextTitle: "LidKeep Status Icon",
                kCGPDFContextCreator: "LidKeep native icon exporter"] as CFDictionary
    guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, info) else {
        throw ExportError.failed("Cannot create vector PDF context")
    }
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: 18)
    context.scaleBy(x: 18 / 24, y: -18 / 24)
    drawStatusIcon(context)
    context.endPDFPage()
    context.closePDF()
    let data = buffer as Data
    guard let provider = CGDataProvider(data: data as CFData),
          let document = CGPDFDocument(provider), document.numberOfPages == 1,
          document.page(at: 1)?.getBoxRect(.mediaBox) == box else {
        throw ExportError.failed("StatusIcon.pdf must contain one 18×18pt page")
    }
    return data
}

func export(to destination: URL, preview: URL?) throws {
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    let scratch = files.temporaryDirectory.appendingPathComponent("lidkeep-icons-\(UUID().uuidString)")
    let iconset = scratch.appendingPathComponent("AppIcon.iconset")
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let side = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            let data = try png(side: side, coordinateSize: 256, draw: drawAppIcon)
            guard let image = NSBitmapImageRep(data: data), image.pixelsWide == side,
                  image.pixelsHigh == side else { throw ExportError.failed("Invalid \(name)") }
            try data.write(to: iconset.appendingPathComponent(name), options: .atomic)
        }
    }
    let target = destination.appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", target.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let icon = NSImage(contentsOf: target), !icon.representations.isEmpty,
          (try Data(contentsOf: target)).count > 0 else {
        throw ExportError.failed("iconutil failed to produce a valid AppIcon.icns")
    }
    try statusPDF().write(to: destination.appendingPathComponent("StatusIcon.pdf"), options: .atomic)
    for (source, output) in [("design/icon-lab/icons/35.svg", "AppIcon.svg"),
                             ("design/icon-lab/menu/03.svg", "StatusIcon.svg")] {
        try Data(contentsOf: root.appendingPathComponent(source))
            .write(to: destination.appendingPathComponent(output), options: .atomic)
    }
    if let preview {
        try files.createDirectory(at: preview, withIntermediateDirectories: true)
        for side in [16, 32, 256, 1024] {
            try png(side: side, coordinateSize: 256, draw: drawAppIcon)
                .write(to: preview.appendingPathComponent("AppIcon-\(side).png"), options: .atomic)
        }
        for side in [18, 36, 180] {
            try png(side: side, coordinateSize: 24, draw: drawStatusIcon)
                .write(to: preview.appendingPathComponent("StatusIcon-\(side).png"), options: .atomic)
        }
        try png(side: 180, coordinateSize: 24) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            drawStatusIcon(context)
        }.write(to: preview.appendingPathComponent("StatusIcon-180-white.png"), options: .atomic)
    }
    print("Exported AppIcon.icns (10 PNG representations), StatusIcon.pdf (18×18pt), and approved SVG sources to \(destination.path)")
}

do {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw ExportError.failed("Usage: swift scripts/generate-icons.swift <output-dir> [preview-dir]")
    }
    let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let preview = CommandLine.arguments.count == 3
        ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
    try export(to: destination, preview: preview)
} catch {
    fputs("Icon export failed: \(error)\n", stderr)
    exit(1)
}
