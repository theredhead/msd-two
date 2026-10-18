import Foundation

struct Binding: Codable, Identifiable {
  var id: Int
  var name: String
  var action = NoAction.name
  var argument = ""
  var keyCode: UInt16 = 0
  var modifiers: UInt64 = 0
  /// Display label of the recorded shortcut; nil until one is recorded, since key code 0 is A.
  var recordedShortcut: String?
  var imagePath: String?

  /// Earlier versions stored the shortcut label in `argument`.
  mutating func migrateRecordedShortcut() {
    guard recordedShortcut == nil, action == KeystrokeAction().name, !argument.isEmpty else {
      return
    }
    recordedShortcut = argument
  }
}

struct MacroPadScene: Codable, Identifiable {
  var id: UUID
  /// Includes every device control; the persisted name remains `keys` for compatibility.
  var keys: [Binding]
  var backgroundPath: String? = nil
}

struct SavedConfiguration: Codable {
  /// Version 2 introduced `Binding.recordedShortcut`; earlier files have no version.
  static let currentVersion = 3

  /// Version 3 stores all controls in each scene. `bindings` is retained for migration.
  var version: Int?
  var bindings: [Binding]
  var scenes: [MacroPadScene]
  var activeSceneID: UUID

  func migratedScenes() -> [MacroPadScene] {
    let defaults = DefaultConfiguration.bindings()
    let shared = DefaultConfiguration.merging(
      bindings, into: defaults.filter { !(1...6).contains($0.id) })
    return scenes.map { scene in
      var result = scene
      result.keys = DefaultConfiguration.merging(
        scene.keys + ((version ?? 1) < 3 ? shared : []), into: defaults)
      return result
    }
  }

}

/// A decoded bindings.json, in either the current or the pre-scenes format.
enum LoadedConfiguration {
  case current(SavedConfiguration)
  case legacy([Binding])

  static func decode(_ data: Data) throws -> LoadedConfiguration {
    do {
      return .current(try JSONDecoder().decode(SavedConfiguration.self, from: data))
    } catch {
      if let legacy = try? JSONDecoder().decode([Binding].self, from: data) {
        return .legacy(legacy)
      }
      throw error
    }
  }
}

/// The controls and actions a new configuration starts with.
enum DefaultConfiguration {
  static func bindings() -> [Binding] {
    let defaults: [(Int, String)] =
      (1...6).map { ($0, "LCD key \($0)") } + [
        (0x51, "Large dial clockwise"), (0x50, "Large dial counterclockwise"),
        (0x35, "Large dial press"), (0x91, "Left small dial clockwise"),
        (0x90, "Left small dial counterclockwise"), (0x33, "Left small dial press"),
        (0x61, "Right small dial clockwise"), (0x60, "Right small dial counterclockwise"),
        (0x34, "Right small dial press"), (0x25, "Left circular button"),
        (0x30, "Middle circular button"), (0x31, "Right circular button"),
      ]
    return defaults.map { code, name in
      var b = Binding(id: code, name: name)
      if code == 0x51 { b.action = VolumeAdjustment(direction: .up).name }
      if code == 0x50 { b.action = VolumeAdjustment(direction: .down).name }
      if code == 0x35 { b.action = MuteAction().name }
      return b
    }
  }

  static func merging(_ saved: [Binding], into defaults: [Binding]) -> [Binding] {
    defaults.map { fallback in
      saved.first { $0.id == fallback.id } ?? fallback
    }
  }
}

/// A preset replaces all three gestures, leaving other controls untouched.
enum DialPreset: String, CaseIterable {
  case volume = "Volume"
  case macBrightness = "Mac brightness"
  case padBrightness = "Pad brightness"
  case media = "Media"
  case scenes = "Scenes"
  case clear = "Clear dial"

  var actions: [any MacroAction] {
    switch self {
    case .volume: return [VolumeAdjustment(direction: .down), MuteAction(), VolumeAdjustment(direction: .up)]
    case .macBrightness: return [MacBrightnessAdjustment(direction: .down), ToggleMacAutomaticBrightnessAction(), MacBrightnessAdjustment(direction: .up)]
    case .padBrightness: return [PadBrightnessAdjustment(direction: .down), TogglePadAdaptiveBrightnessAction(), PadBrightnessAdjustment(direction: .up)]
    case .media: return [MediaKey.previousTrack, MediaKey.playPause, MediaKey.nextTrack]
    case .scenes: return [SceneNavigationAction(direction: .previous), NoAction(), SceneNavigationAction(direction: .next)]
    case .clear: return [NoAction(), NoAction(), NoAction()]
    }
  }

  static func controls(for code: Int) -> [Int]? {
    [[0x50, 0x35, 0x51], [0x90, 0x33, 0x91], [0x60, 0x34, 0x61]].first { $0.contains(code) }
  }
}
