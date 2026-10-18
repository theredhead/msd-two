import AppKit
import IOKit.hid

extension Model {
  func startHID() {
    manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(
      manager,
      [kIOHIDVendorIDKey: 0x0B00, kIOHIDProductIDKey: 0x1001, kIOHIDPrimaryUsagePageKey: 0xFFA0]
        as CFDictionary)
    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      { context, result, _, device in
        guard let context else { return }
        let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess else { return }
        let size = max(
          (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?
            .intValue ?? 512, 512)
        let input =
          model.inputBuffers[ObjectIdentifier(device)]
          ?? (UnsafeMutablePointer<UInt8>.allocate(capacity: size), size)
        model.inputBuffers[ObjectIdentifier(device)] = input
        IOHIDDeviceRegisterInputReportCallback(
          device, input.buffer, input.size,
          { context, result, _, _, _, report, length in
            guard let context, result == kIOReturnSuccess, length >= 10 else { return }
            let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
            guard report[0] == 0x41, report[1] == 0x43, report[2] == 0x4b, report[5] == 0x4f,
              report[6] == 0x4b
            else { return }
            NSLog(
              "HID input %@",
              (0..<min(length, 24)).map { String(format: "%02x", report[$0]) }.joined(
                separator: " "))
            model.handle(Int(report[9]))
          }, context)
        model.display?.stop()
        model.displayDevice = device
        model.display = LCDSession(device: device) { error in
          DispatchQueue.main.async { model.message = error.localizedDescription }
        }
        let frame = model.displayFrame()
        model.display?.start(
          images: frame?.images ?? [], background: frame?.background ?? [],
          brightness: model.displayBrightness)
        model.connected = true
        model.message = "CS06 / MSD-TWO connected"
      }, context)
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      { context, _, _, device in
        guard let context else { return }
        let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
        model.releaseInput(for: device, context: context)
        guard model.displayDevice === device else { return }
        model.display?.stop()
        model.display = nil
        model.displayDevice = nil
        model.connected = false
        model.message = "Device disconnected"
      }, context)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    let result = IOHIDManagerOpen(manager, 0)
    if result != kIOReturnSuccess { message = String(format: "HID access failed: 0x%08x", result) }
  }

  /// Stops report delivery for a removed device, then frees the buffer IOKit copied reports into.
  private func releaseInput(for device: IOHIDDevice, context: UnsafeMutableRawPointer) {
    guard let input = inputBuffers.removeValue(forKey: ObjectIdentifier(device)) else { return }
    // IOKit matches registrations by context, so it must be the one used to register.
    IOHIDDeviceRegisterInputReportCallback(device, input.buffer, input.size, nil, context)
    IOHIDDeviceUnscheduleFromRunLoop(
      device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    // Reports are copied on the main run loop; free only after any in-flight turn completes.
    DispatchQueue.main.async { input.buffer.deallocate() }
  }

  func handle(_ code: Int) {
    guard recording == nil else { return }
    let binding: Binding?
    if (1...6).contains(code) {
      binding = scenes[activeSceneIndex].keys.first { $0.id == code }
    } else {
      binding = bindings.first { $0.id == code }
    }
    guard let binding else {
      message = String(format: "Unmapped event: 0x%02x", code)
      return
    }
    message = "\(binding.name) → \(binding.action)"
    execute(binding)
    if repairKeyBorders && (1...6).contains(code) { display?.repairBorderAfterKeypress(code) }
  }
}
