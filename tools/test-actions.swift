import AppKit
import UniformTypeIdentifiers

/// Records what actions ask of the app without touching real devices or settings.
final class FakeContext: ActionContext {
  var displayBrightness = 40
  var padFollowMac = false
  var reports: [String] = []
  var accessibilityRequests = 0
  var sceneOffsets: [Int] = []
  var padDeltas: [Int] = []

  func report(_ message: String) { reports.append(message) }

  func requestAccessibilityAccess() -> Bool {
    accessibilityRequests += 1
    return false
  }

  func changeScene(by offset: Int) { sceneOffsets.append(offset) }
  func changePadBrightness(by delta: Int) { padDeltas.append(delta) }
  func togglePadFollowMac() throws { padFollowMac.toggle() }
  func syncPadBrightness() {}
}

@main
struct ActionChecks {
  static func main() {
    // Migrating shared dial/button bindings must preserve each scene and its artwork.
    var shared = Binding(id: 0x91, name: "Left small dial clockwise")
    shared.action = ShellScriptAction().name
    shared.argument = "echo preserved"
    shared.recordedShortcut = "⌘A"
    let first = MacroPadScene(id: UUID(), keys: [Binding(id: 1, name: "LCD key 1")], backgroundPath: "/first.png")
    let second = MacroPadScene(id: UUID(), keys: [Binding(id: 1, name: "LCD key 1", action: "Mute")])
    let old = SavedConfiguration(version: 2, bindings: [shared], scenes: [first, second], activeSceneID: second.id)
    let migrated = old.migratedScenes()
    precondition(migrated.count == 2 && migrated[0].id == first.id)
    precondition(migrated[0].backgroundPath == "/first.png")
    for scene in migrated {
      precondition(scene.keys.count == DefaultConfiguration.bindings().count)
      let dial = scene.keys.first { $0.id == shared.id }!
      precondition(dial.argument == shared.argument && dial.recordedShortcut == shared.recordedShortcut)
    }
    precondition(migrated[1].keys.first { $0.id == 1 }!.action == "Mute")
    var independent = migrated
    independent[0].keys[6].action = "Mute"
    let current = SavedConfiguration(version: 3, bindings: [], scenes: independent, activeSceneID: first.id)
    let roundTrip = try! JSONDecoder().decode(SavedConfiguration.self, from: JSONEncoder().encode(current)).migratedScenes()
    precondition(roundTrip[0].keys[6].action == "Mute")
    precondition(roundTrip[1].keys[6].action != "Mute")
    precondition(DialPreset.volume.actions.map(\.name) == ["Volume down", "Mute", "Volume up"])
    precondition(DialPreset.scenes.actions.map(\.name) == ["Previous scene", "None", "Next scene"])
    for code in [0x35, 0x33, 0x34] {
      precondition(DialPreset.controls(for: code)?.count == 3)
    }
    print("PASS whole-device scene migration, persistence, independence, and dial preset ordering")

    // Persisted names must never change: existing bindings.json files store them.
    let expected: [(String, [String])] = [
      (
        "Media & Audio",
        ["Previous track", "Play/pause", "Next track", "Volume up", "Volume down", "Mute"]
      ),
      (
        "Mac Display",
        [
          "Mac display brightness up", "Mac display brightness down",
          "Toggle Mac automatic brightness",
        ]
      ),
      (
        "MSD-TWO Display",
        ["MSD-TWO brightness up", "MSD-TWO brightness down", "Toggle MSD-TWO adaptive brightness"]
      ),
      ("Scenes", ["Next scene", "Previous scene"]),
      ("Keyboard & Automation", ["Keystroke", "Open application", "Open folder", "AppleScript", "Shell script"]),
    ]
    precondition(ActionCatalog.groups.map(\.name) == expected.map(\.0))
    for (group, names) in zip(ActionCatalog.groups, expected) {
      precondition(group.actions.map(\.name) == names.1, "Names changed in \(group.name)")
      for name in names.1 {
        precondition(ActionCatalog.action(named: name).name == name)
      }
    }
    precondition(ActionCatalog.action(named: "None") is NoAction)
    precondition(ActionCatalog.action(named: "Retired action") is NoAction)
    precondition(
      ActionCatalog.action(named: "Display brightness up").name == "MSD-TWO brightness up")
    precondition(
      ActionCatalog.action(named: "Display brightness down").name == "MSD-TWO brightness down")
    print("PASS catalog: menu order, persisted names, legacy aliases, unknown names")

    var binding = Binding(id: 1, name: "LCD key 1")
    precondition(!ActionCatalog.none.isReady(binding))
    for action in ActionCatalog.groups.flatMap(\.actions) where action.symbol != nil {
      precondition(action.icon(for: binding) != nil, "Missing icon for \(action.name)")
    }
    let open = OpenApplicationAction()
    precondition(open.icon(for: binding) == nil)
    binding.argument = "/System/Applications/Calculator.app"
    precondition(open.icon(for: binding) != nil)
    precondition(open.artworkKey(for: binding) == binding.argument)
    precondition(open.searchTerm(for: binding) == "Calculator icon")
    precondition(VolumeAdjustment(direction: .up).searchTerm(for: binding) == "Volume up icon")
    print("PASS presentation: symbol icons, application icon, artwork keys, search terms")

    let context = FakeContext()
    let folder = OpenFolderAction()
    let folderRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folderRoot) }
    binding.action = folder.name
    binding.argument = folderRoot.path
    precondition(folder.isReady(binding))
    precondition(folder.icon(for: binding) != nil)
    let savedFolder = try! JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(binding))
    precondition(savedFolder.action == folder.name && savedFolder.argument == folderRoot.path)
    binding.argument = folderRoot.appendingPathComponent("missing").path
    precondition(!folder.isReady(binding))
    folder.perform(binding, in: context)
    precondition(context.reports.last == "Choose an existing folder for LCD key 1 first")
    let file = folderRoot.appendingPathComponent("file.txt")
    try! Data().write(to: file)
    binding.argument = file.path
    precondition(!folder.isReady(binding))
    binding.argument = ""
    precondition(!folder.isReady(binding))
    print("PASS folders: directory validation, file rejection, icon, persistence, missing-folder reporting")

    // Safari in /Applications is a symlink, so classify its destination, not public.symlink.
    let appURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    let linkURL = folderRoot.appendingPathComponent("Linked Calculator.app")
    try! FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: appURL)
    let aliasURL = folderRoot.appendingPathComponent("Calculator alias")
    let aliasData = try! appURL.bookmarkData(options: .suitableForBookmarkFile,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    try! URL.writeBookmarkData(aliasData, to: aliasURL)
    for source in [appURL, linkURL, aliasURL] {
      let resolved = try! DroppedFile.resolvedURL(source)
      precondition(resolved == appURL.resolvingSymlinksInPath())
      precondition(try! resolved.resourceValues(forKeys: [.contentTypeKey]).contentType!
        .conforms(to: .applicationBundle))
      binding.imagePath = "/old-custom-icon.png"
      let dropped = DroppedFile.applicationBinding(binding, url: resolved)
      precondition(dropped.action == OpenApplicationAction.name)
      precondition(dropped.argument == resolved.path && dropped.imagePath == nil)
      precondition(dropped.id == binding.id && dropped.name == binding.name)
    }
    print("PASS app drops: direct bundles, symbolic links, Finder aliases, action and automatic icon")
    let keystroke = KeystrokeAction()
    binding.argument = ""
    precondition(!keystroke.isReady(binding))
    keystroke.perform(binding, in: context)
    precondition(context.reports.last == "Record a keystroke for LCD key 1 first")
    precondition(context.accessibilityRequests == 0)
    binding.recordedShortcut = "⌘C"
    precondition(keystroke.isReady(binding))
    keystroke.perform(binding, in: context)
    precondition(context.accessibilityRequests == 1, "Keystrokes must require Accessibility")

    SceneNavigationAction(direction: .next).perform(binding, in: context)
    SceneNavigationAction(direction: .previous).perform(binding, in: context)
    precondition(context.sceneOffsets == [1, -1])
    PadBrightnessAdjustment(direction: .up).perform(binding, in: context)
    PadBrightnessAdjustment(direction: .down).perform(binding, in: context)
    precondition(context.padDeltas == [5, -5])
    TogglePadAdaptiveBrightnessAction().perform(binding, in: context)
    precondition(context.padFollowMac)
    precondition(
      PadBrightnessAdjustment(direction: .up).summary(in: context)?.contains("40%") == true)
    print(
      "PASS behavior: keystroke readiness and permission, scenes, pad brightness, adaptive toggle")

    precondition(AppleScriptAction().arguments(for: "beep") == ["-e", "beep"])
    precondition(ShellScriptAction().arguments(for: "true") == ["-c", "true"])
    binding.argument = "echo failed >&2; exit 3"
    ShellScriptAction().perform(binding, in: context)
    binding.argument = "exit 0"
    let before = context.reports.count
    let deadline = Date().addingTimeInterval(10)
    while context.reports.count < before + 1 && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(context.reports.last == "failed\n", "Got \(context.reports)")
    ShellScriptAction().perform(binding, in: context)
    while context.reports.count < before + 2 && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(context.reports.last == "", "Successful script should clear the message")
    print("PASS scripts: interpreter arguments, stderr on failure, cleared message on success")
  }
}
