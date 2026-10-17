import Foundation
import IOKit.hid

setbuf(stdout, nil)
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: 0x0B00, kIOHIDProductIDKey: 0x1001, kIOHIDPrimaryUsagePageKey: 0xFFA0]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("Manager open: \(String(format: "0x%08x", status))")
guard status == kIOReturnSuccess else { exit(1) }
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
guard !devices.isEmpty else { print("No CS06 vendor interface found"); exit(2) }
var buffers: [UnsafeMutablePointer<UInt8>] = []
let callback: IOHIDReportCallback = { _, result, _, type, reportID, report, length in
    let bytes = UnsafeBufferPointer(start: report, count: length)
    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    print("\(ISO8601DateFormatter().string(from: Date())) result=\(result) type=\(type.rawValue) id=\(reportID) len=\(length) hex=\(hex)")
}
for device in devices {
    let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 512
    print("Listening: \(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) ?? "unknown" as CFString), max input=\(size)")
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 512))
    buffers.append(buffer)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, max(size, 512), callback, nil)
}
print("READY — vendor interface only; no output commands sent")
CFRunLoopRun()
