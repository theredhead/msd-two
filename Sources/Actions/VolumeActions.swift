import CoreAudio
import Foundation

/// Steps the default output volume by 2%.
struct VolumeAdjustment: AdjustmentAction {
  static let subject = "Volume"
  let direction: AdjustmentDirection

  var symbol: String? { direction == .up ? "speaker.plus.fill" : "speaker.minus.fill" }

  func summary(in context: ActionContext) -> String? {
    "Adjusts the current audio output by 2% per click."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    let delta = Float32(direction.sign) * 0.02
    runInBackground(in: context) { try Audio.changeVolume(delta) }
  }
}

struct MuteAction: MacroAction {
  let name = "Mute"
  let symbol: String? = "speaker.slash.fill"

  func perform(_ binding: Binding, in context: ActionContext) {
    runInBackground(in: context) { try Audio.toggleMute() }
  }
}

/// Default-output volume and mute through CoreAudio.
enum Audio {
  static func address(
    _ selector: AudioObjectPropertySelector,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func device() throws -> AudioDeviceID {
    var a = address(
      kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
    var d: AudioDeviceID = 0
    var size = UInt32(MemoryLayout.size(ofValue: d))
    guard
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d)
        == noErr, d != 0
    else { throw ActionError.failed("No default audio output") }
    return d
  }

  static func writable(_ d: AudioDeviceID, _ a: inout AudioObjectPropertyAddress) -> Bool {
    var settable: DarwinBoolean = false
    return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &settable) == noErr
      && settable.boolValue
  }

  static func changeVolume(_ delta: Float32) throws {
    let d = try device()
    var changed = false
    // Prefer the master volume; otherwise adjust available output channels.
    for element: UInt32 in [0, 1, 2] {
      var a = address(kAudioDevicePropertyVolumeScalar, element)
      guard writable(d, &a) else { continue }
      var v: Float32 = 0
      var size: UInt32 = 4
      guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr else { continue }
      v = min(1, max(0, v + delta))
      if AudioObjectSetPropertyData(d, &a, 0, nil, 4, &v) == noErr { changed = true }
      if element == 0 && changed { break }
    }
    guard changed else {
      throw ActionError.failed("This audio output does not expose software volume control")
    }
  }

  static func toggleMute() throws {
    let d = try device()
    var a = address(kAudioDevicePropertyMute)
    guard writable(d, &a) else {
      throw ActionError.failed("This audio output does not expose mute control")
    }
    var mute: UInt32 = 0
    var size: UInt32 = 4
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &mute) == noErr else {
      throw ActionError.failed("Cannot read mute state")
    }
    mute = mute == 0 ? 1 : 0
    guard AudioObjectSetPropertyData(d, &a, 0, nil, 4, &mute) == noErr else {
      throw ActionError.failed("Cannot set mute")
    }
  }
}
