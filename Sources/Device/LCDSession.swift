import Foundation
import IOKit.hid

// Independently implemented from the MSD-TWO wire protocol documented in
// crabdeck and mirajazz. No vendor binary is loaded or executed.
final class LCDSession {
  private let device: IOHIDDevice
  private let queue = DispatchQueue(label: "MacroPad.display")
  private var timer: DispatchSourceTimer?
  private let failure: (Error) -> Void
  private var stopped = false
  private var lastImages: [[UInt8]] = []
  private var lastBackground: [UInt8]?
  private var borderRepairGeneration = 0
  private var pendingFrame: (images: [[UInt8]], background: [UInt8])?

  init(device: IOHIDDevice, failure: @escaping (Error) -> Void) {
    self.device = device
    self.failure = failure
  }

  func start(images: [[UInt8]], background: [UInt8], brightness: Int) {
    queue.async { [self] in
      do {
        try self.command("DIS")
        try self.command("LIG", [0, 0, 0])
        try self.command("LIG", [0, 0, UInt8(min(100, max(0, brightness)))])
        try self.apply(images: images, background: background)
        try self.command("CONNECT")
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
          guard let self, !self.stopped else { return }
          do { try self.command("CONNECT") } catch { self.failure(error) }
        }
        self.timer = timer
        timer.resume()
      } catch { self.failure(error) }
    }
  }

  func setBrightness(_ percent: Int, completion: @escaping () -> Void) {
    queue.async { [self] in
      guard !stopped else { return }
      do {
        try command("LIG", [0, 0, UInt8(min(100, max(0, percent)))])
        completion()
      } catch { failure(error) }
    }
  }

  /// Only the newest frame queued behind an in-progress transfer is written.
  func update(images: [[UInt8]], background: [UInt8]) {
    queue.async { [self] in
      let drainScheduled = pendingFrame != nil
      pendingFrame = (images, background)
      guard !drainScheduled else { return }
      queue.async { [self] in
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        guard !stopped else { return }
        do { try apply(images: frame.images, background: frame.background) } catch {
          failure(error)
        }
      }
    }
  }

  // Probe whether a key-image write resets the firmware's border state.
  // This deliberately avoids the shared-background transfer entirely.
  func repairBorderAfterKeypress(_ key: Int) {
    queue.async { [self] in
      borderRepairGeneration += 1
      let generation = borderRepairGeneration
      queue.asyncAfter(deadline: .now() + 0.35) { [self] in
        guard !stopped, generation == borderRepairGeneration,
          (1...6).contains(key), lastImages.count == 6
        else { return }
        do { try upload(lastImages[key - 1], key: UInt8(key)) } catch { failure(error) }
      }
    }
  }

  private func apply(images: [[UInt8]], background: [UInt8]) throws {
    guard images.count == 6, images.allSatisfy({ !$0.isEmpty }),
      background.count == Artwork.backgroundByteCount
    else { throw ActionError.failed("Cannot render LCD images; the display was not updated") }
    if background != lastBackground {
      // A background transfer clears the device's key layer, even when
      // the desired icon bytes haven't changed. Invalidate before writing
      // so a failed transfer also leaves the next update able to recover.
      lastImages = []
      let count = UInt32(background.count)
      try command(
        "LOG",
        [
          UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255),
          UInt8(count & 255), 1,
        ])
      for offset in stride(from: 0, to: background.count, by: 1024) {
        try write(Array(background[offset..<min(offset + 1024, background.count)]))
      }
      try command("STP")
      lastBackground = background
      Thread.sleep(forTimeInterval: 0.5)
    }
    for (index, jpeg) in images.enumerated() {
      if lastImages.count != images.count || lastImages[index] != jpeg {
        try upload(jpeg, key: UInt8(index + 1))
      }
    }
    lastImages = images
  }

  func stop() {
    queue.async {
      self.stopped = true
      self.timer?.cancel()
      self.timer = nil
    }
  }

  private func write(_ bytes: [UInt8]) throws {
    guard bytes.count <= 1024 else { throw ActionError.failed("LCD report too large") }
    var report = bytes
    report += [UInt8](repeating: 0, count: 1024 - report.count)
    let result = report.withUnsafeBufferPointer {
      IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
    }
    guard result == kIOReturnSuccess else {
      throw ActionError.failed(String(format: "LCD write failed: 0x%08x", result))
    }
  }

  private func command(_ verb: String, _ payload: [UInt8] = []) throws {
    try write(Array("CRT".utf8) + [0, 0] + Array(verb.utf8) + payload)
  }

  private func upload(_ jpeg: [UInt8], key: UInt8) throws {
    guard jpeg.count < 65536 else { throw ActionError.failed("LCD image too large") }
    try command("BAT", [0, 0, UInt8(jpeg.count >> 8), UInt8(jpeg.count & 255), key])
    var bytes = jpeg
    // Zero the staging tail as required by this device's image protocol.
    bytes += [UInt8](repeating: 0, count: max(0, 8192 - bytes.count))
    for offset in stride(from: 0, to: bytes.count, by: 1024) {
      try write(Array(bytes[offset..<min(offset + 1024, bytes.count)]))
    }
    try command("STP")
  }
}
