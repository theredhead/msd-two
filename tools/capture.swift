import AppKit
import Foundation
import IOKit.hid

setbuf(stdout, nil)
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
  kIOHIDVendorIDKey: 0x0B00, kIOHIDProductIDKey: 0x1001, kIOHIDPrimaryUsagePageKey: 0xFFA0,
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("Manager open: \(String(format: "0x%08x", status))")
guard status == kIOReturnSuccess else { exit(1) }
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
guard !devices.isEmpty else {
  print("No CS06 vendor interface found")
  exit(2)
}
var buffers: [UnsafeMutablePointer<UInt8>] = []
let callback: IOHIDReportCallback = { _, result, _, type, reportID, report, length in
  let bytes = UnsafeBufferPointer(start: report, count: length)
  let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
  print(
    "\(ISO8601DateFormatter().string(from: Date())) result=\(result) type=\(type.rawValue) id=\(reportID) len=\(length) hex=\(hex)"
  )
}
for device in devices {
  let size =
    (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
    ?? 512
  print(
    "Listening: \(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) ?? "unknown" as CFString), max input=\(size)"
  )
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 512))
  buffers.append(buffer)
  IOHIDDeviceRegisterInputReportCallback(device, buffer, max(size, 512), callback, nil)
}
if CommandLine.arguments.contains("--version") {
  for device in devices {
    var packet = [UInt8](repeating: 0, count: 1024)
    packet.replaceSubrange(0..<3, with: Array("CRT".utf8))
    packet.replaceSubrange(5..<8, with: Array("VER".utf8))
    let result = packet.withUnsafeBufferPointer {
      IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
    }
    print("Version query output: \(String(format: "0x%08x", result))")
  }
}
if CommandLine.arguments.contains("--heartbeat") {

  func heartbeat() {
    for device in devices {
      var packet = [UInt8](repeating: 0, count: 1024)
      packet.replaceSubrange(0..<3, with: Array("CRT".utf8))
      packet.replaceSubrange(5..<12, with: Array("CONNECT".utf8))
      let result = packet.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
      }
      print("Heartbeat output: \(String(format: "0x%08x", result))")
    }
  }
  if CommandLine.arguments.contains("--software-mode") {
    for device in devices {
      var packet = [UInt8](repeating: 0, count: 1024)
      packet.replaceSubrange(0..<3, with: Array("CRT".utf8))
      packet.replaceSubrange(5..<8, with: Array("MOD".utf8))
      packet[10] = 0x32
      let result = packet.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
      }
      print("Software mode output: \(String(format: "0x%08x", result))")
    }
  }
  if CommandLine.arguments.contains("--wake") {
    for device in devices {
      var packet = [UInt8](repeating: 0, count: 1024)
      packet.replaceSubrange(0..<3, with: Array("CRT".utf8))
      packet.replaceSubrange(5..<8, with: Array("DIS".utf8))
      let result = packet.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
      }
      print("Wake output: \(String(format: "0x%08x", result))")
    }
  }
  if CommandLine.arguments.contains("--n3-init") {
    for device in devices {
      for brightness: UInt8 in [0, 80] {
        var packet = [UInt8](repeating: 0, count: 1024)
        packet.replaceSubrange(0..<3, with: Array("CRT".utf8))
        packet.replaceSubrange(5..<8, with: Array("LIG".utf8))
        packet[10] = brightness
        let result = packet.withUnsafeBufferPointer {
          IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        print("N3 brightness \(brightness): \(String(format: "0x%08x", result))")
      }
    }
  }
  if CommandLine.arguments.contains("--test-image") {
    let image = NSImage(size: NSSize(width: 60, height: 60))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 60, height: 60).fill()
    ("1" as NSString).draw(
      at: NSPoint(x: 19, y: 10),
      withAttributes: [.font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white])
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let jpeg = [UInt8](bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!)
    for device in devices {
      func send(_ bytes: [UInt8]) {
        var packet = bytes
        packet += [UInt8](repeating: 0, count: 1024 - packet.count)
        let result = packet.withUnsafeBufferPointer {
          IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        print("Image packet output: \(String(format: "0x%08x", result))")
      }
      send(
        Array("CRT".utf8) + [0, 0] + Array("BAT".utf8) + [
          0, 0, UInt8(jpeg.count >> 8), UInt8(jpeg.count & 255), 1,
        ])
      var padded = jpeg
      padded += [UInt8](repeating: 0, count: max(0, 8192 - padded.count))
      for offset in stride(from: 0, to: padded.count, by: 1024) {
        send(Array(padded[offset..<min(offset + 1024, padded.count)]))
      }
      send(Array("CRT".utf8) + [0, 0] + Array("STP".utf8))
      print("Test image: \(jpeg.count) JPEG bytes, key 1")
    }
  }
  heartbeat()
  let timer = Timer(timeInterval: 5, repeats: true) { _ in heartbeat() }
  RunLoop.current.add(timer, forMode: .default)
}
print("READY — listening for vendor input")
CFRunLoopRun()
