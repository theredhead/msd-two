import AppKit

@main
struct ArtworkChecks {
  static func main() {
    let wall = NSImage(size: NSSize(width: 320, height: 240))
    wall.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 320, height: 240).fill()
    wall.unlockFocus()
    let source = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<64 {
      for x in 0..<64 {
        source.setColor(
          NSColor(deviceRed: 0, green: 0, blue: 1, alpha: x < 16 ? 0 : 0.5), atX: x, y: y)
      }
    }
    let icon = NSImage(data: source.representation(using: .png, properties: [:])!)!
    precondition(!Artwork.requiresCrop(image: icon, aspectRatio: 1))
    precondition(Artwork.requiresCrop(image: wall, aspectRatio: 1))
    precondition(!Artwork.requiresCrop(image: wall, aspectRatio: 4.0 / 3.0))
    precondition(Artwork.requiresCrop(image: icon, aspectRatio: 4.0 / 3.0))
    let portrait = NSImage(size: NSSize(width: 240, height: 320))
    precondition(Artwork.requiresCrop(image: portrait, aspectRatio: 1))
    precondition(Artwork.requiresCrop(image: portrait, aspectRatio: 4.0 / 3.0))
    let imported = NSBitmapImageRep(data: Artwork.png(image: icon)!)!
    precondition(imported.pixelsWide == 64 && imported.pixelsHigh == 64)
    precondition(imported.colorAt(x: 5, y: 32)!.alphaComponent < 0.05)
    precondition(abs(imported.colorAt(x: 32, y: 32)!.alphaComponent - 0.5) < 0.05)
    print("PASS dropped images: crop routing, PNG dimensions, and alpha preservation")
    for index in 0..<6 {
      let result = Artwork.render(
        image: icon, width: 64, height: 64, wallpaper: wall, keyIndex: index)!
      let clear = result.colorAt(x: 5, y: 32)!.usingColorSpace(.deviceRGB)!
      let half = result.colorAt(x: 32, y: 32)!.usingColorSpace(.deviceRGB)!
      precondition(clear.redComponent > 0.95 && clear.blueComponent < 0.05)
      precondition(abs(half.redComponent - 0.5) < 0.05 && abs(half.blueComponent - 0.5) < 0.05)
      let jpeg = Artwork.jpeg(image: icon, width: 64, height: 64, wallpaper: wall, keyIndex: index)!
      let decoded = NSBitmapImageRep(data: Data(jpeg))!
      precondition(decoded.pixelsWide == 64 && decoded.pixelsHigh == 64)
    }
    print(
      "PASS all six tiles: transparent pixels retain wallpaper; half-alpha pixels blend; wire JPEG stays 64×64"
    )

  }
}
