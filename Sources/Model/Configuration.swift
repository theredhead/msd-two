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
  var keys: [Binding]
  var backgroundPath: String? = nil
}

struct SavedConfiguration: Codable {
  /// Version 2 introduced `Binding.recordedShortcut`; earlier files have no version.
  static let currentVersion = 2

  var version: Int?
  var bindings: [Binding]
  var scenes: [MacroPadScene]
  var activeSceneID: UUID
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
