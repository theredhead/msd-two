import AppKit

enum Artwork {
  static func requiresCrop(image: NSImage, aspectRatio: CGFloat) -> Bool {
    abs(image.size.width - image.size.height * aspectRatio) >= 0.01
  }

  static func png(image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }

  // N3 background transport uses a 240×320 RGB565 bitmap, not JPEG.
  static func backgroundRGB565(image: NSImage?) -> [UInt8] {
    guard let image else { return [UInt8](repeating: 0, count: 240 * 320 * 2) }
    guard let bitmap = render(image: image, width: 240, height: 320, rotate: true) else {
      return []
    }
    var result = [UInt8]()
    result.reserveCapacity(240 * 320 * 2)
    for y in 0..<320 {
      for x in 0..<240 {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          result += [0, 0]
          continue
        }
        let r = UInt16(min(31, max(0, Int(color.redComponent * 31))))
        let g = UInt16(min(63, max(0, Int(color.greenComponent * 63))))
        let b = UInt16(min(31, max(0, Int(color.blueComponent * 31))))
        let value = (r << 11) | (g << 5) | b
        result += [UInt8(value & 255), UInt8(value >> 8)]
      }
    }
    return result
  }

  // Source PNG alpha is preserved until this final composition. Both the
  // wallpaper and tile crops use the same upright 320×240 canvas.
  static func keyRect(_ index: Int) -> NSRect {
    let column = index % 3
    let row = index / 3
    return NSRect(
      x: (CGFloat(column) + 0.5) * (320.0 / 3.0) - 32,
      y: (1.5 - CGFloat(row)) * 120 - 32, width: 64, height: 64)
  }

  static func jpeg(
    image: NSImage?, width: Int, height: Int, label: String? = nil, rotate: Bool = false,
    wallpaper: NSImage? = nil, keyIndex: Int? = nil
  ) -> [UInt8]? {
    guard
      let bitmap = render(
        image: image, width: width, height: height, label: label, rotate: rotate,
        wallpaper: wallpaper, keyIndex: keyIndex),
      let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    else { return nil }
    return Array(data)
  }

  static func render(
    image: NSImage?, width: Int, height: Int, label: String? = nil, rotate: Bool = false,
    wallpaper: NSImage? = nil, keyIndex: Int? = nil
  ) -> NSBitmapImageRep? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    if rotate {
      let transform = NSAffineTransform()
      transform.translateX(by: 0, yBy: CGFloat(height))
      transform.rotate(byDegrees: -90)
      transform.concat()
    }
    let target = NSRect(x: 0, y: 0, width: rotate ? height : width, height: rotate ? width : height)
    if let wallpaper, let keyIndex {
      let rect = keyRect(keyIndex)
      // Render the matching wallpaper region first; source-over then
      // resolves transparent and partially transparent icon pixels.
      wallpaper.draw(
        in: NSRect(x: -rect.minX, y: -rect.minY, width: 320, height: 240),
        from: .zero, operation: .sourceOver, fraction: 1)
    }
    if let image { image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1) }
    if let label, !label.isEmpty {
      let text = label as NSString
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.white,
      ]
      text.draw(at: NSPoint(x: 12, y: 12), withAttributes: attrs)
    }
    if width == 64 && height == 64 && CommandLine.arguments.contains("--calibrate") {
      // Three-pixel inset removes keycap masking and outer-pixel ambiguity.
      // Coordinates here are AppKit's bottom-left origin.
      NSColor.red.setFill()
      NSRect(x: 3, y: 58, width: 58, height: 3).fill()
      NSColor.green.setFill()
      NSRect(x: 58, y: 3, width: 3, height: 58).fill()
      NSColor.blue.setFill()
      NSRect(x: 3, y: 3, width: 58, height: 3).fill()
      NSColor.yellow.setFill()
      NSRect(x: 3, y: 3, width: 3, height: 58).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }
}
