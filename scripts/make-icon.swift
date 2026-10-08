#!/usr/bin/env swift
import AppKit
import Foundation

// Scale Pebble's bundled master artwork without cropping, recoloring, or redrawing it.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = project.appendingPathComponent("Resources/Brand/pebble-logo.png")
let iconset = project.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let destination = project.appendingPathComponent("Resources/AppIcon.icns")
let files = FileManager.default
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

let sourceData = try Data(contentsOf: source)
guard let master = NSBitmapImageRep(data: sourceData), let artwork = master.cgImage else {
  fatalError("Cannot load bundled icon artwork: \(source.path)")
}

let representations: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in representations {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!
  let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
  let side = CGFloat(pixels)
  let scale = min(side / CGFloat(artwork.width), side / CGFloat(artwork.height))
  let width = CGFloat(artwork.width) * scale
  let height = CGFloat(artwork.height) * scale
  let bounds = CGRect(x: 0, y: 0, width: side, height: side)
  let fitted = CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
  context.clear(bounds)
  context.interpolationQuality = .high
  context.setBlendMode(.copy)
  context.draw(artwork, in: fitted)
  try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated \(destination.path)")
