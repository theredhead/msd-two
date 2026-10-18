import AppKit
import Darwin

// DisplayServices is loaded at runtime: unsupported systems fail explicitly.
// Signatures verified against DisplayDeck's native brightness implementation.
enum MacBrightness {
  private static let handle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
  private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
  private typealias Setter = @convention(c) (UInt32, Float) -> Int32
  private typealias HasAutomatic = @convention(c) (UInt32) -> Int32
  private typealias GetAutomatic = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Int32
  private typealias SetAutomatic = @convention(c) (UInt32, Bool) -> Int32

  private static func symbol<T>(_ name: String, as type: T.Type) throws -> T {
    guard let handle, let pointer = dlsym(handle, name) else {
      throw ActionError.failed("Mac display brightness control is unavailable")
    }
    return unsafeBitCast(pointer, to: type)
  }

  private static func display() -> UInt32 {
    // Prefer the built-in display even when an external screen is primary.
    for screen in NSScreen.screens {
      if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber,
        CGDisplayIsBuiltin(number.uint32Value) != 0
      {
        return number.uint32Value
      }
    }
    return CGMainDisplayID()
  }

  static func level() throws -> Float {
    let get = try symbol("DisplayServicesGetBrightness", as: Getter.self)
    var value: Float = 0
    guard get(display(), &value) == 0, value.isFinite else {
      throw ActionError.failed("This Mac display does not expose native brightness control")
    }
    return min(1, max(0, value))
  }

  static func change(_ delta: Float) throws {
    let set = try symbol("DisplayServicesSetBrightness", as: Setter.self)
    let value = min(1, max(0, try level() + delta))
    guard set(display(), value) == 0 else {
      throw ActionError.failed("Could not change Mac display brightness")
    }
  }

  static func automatic() throws -> Bool {
    let has = try symbol("DisplayServicesHasAmbientLightCompensation", as: HasAutomatic.self)
    let get = try symbol("DisplayServicesAmbientLightCompensationEnabled", as: GetAutomatic.self)
    let id = display()
    guard has(id) != 0 else {
      throw ActionError.failed("This Mac display does not support automatic brightness")
    }
    var enabled = false
    guard get(id, &enabled) == 0 else {
      throw ActionError.failed("Could not read Mac automatic brightness")
    }
    return enabled
  }

  static func toggleAutomatic() throws {
    let set = try symbol("DisplayServicesEnableAmbientLightCompensation", as: SetAutomatic.self)
    let value = try !automatic()
    guard set(display(), value) == 0, try automatic() == value else {
      throw ActionError.failed("Could not toggle Mac automatic brightness")
    }
  }
}
