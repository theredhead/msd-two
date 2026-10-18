import AppKit
import ApplicationServices

final class Model: ObservableObject, ActionContext {
  @Published var connected = false
  @Published var message = "Waiting for device"
  @Published var recording: Int?
  @Published var scenes: [MacroPadScene] = []
  @Published var activeSceneID = UUID()
  @Published var displayBrightness = 80
  @Published var padFollowMac = false
  let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/MacroPad/bindings.json")
  private var appearanceURL: URL {
    configURL.deletingLastPathComponent().appendingPathComponent("appearance.json")
  }
  private var adaptiveTimer: Timer?
  private var monitor: Any?

  // Shared with the HID and artwork extensions in Model+HID.swift and Model+Artwork.swift.
  var manager: IOHIDManager!
  var displayDevice: IOHIDDevice?
  var display: LCDSession?
  var inputBuffers: [ObjectIdentifier: (buffer: UnsafeMutablePointer<UInt8>, size: Int)] = [:]
  var imagePicker: IconPicker?
  var renderedKeys: [String: [UInt8]] = [:]
  var renderedBackgrounds: [String: [UInt8]] = [:]
  var displayRefreshScheduled = false

  private(set) var configurationRecoveries: [ConfigurationRecovery] = []

  /// Unreadable files that couldn't be backed up are never overwritten.
  private var protectedURLs: Set<URL> {
    Set(configurationRecoveries.filter { $0.backupURL == nil }.map(\.originalURL))
  }

  var activeSceneIndex: Int {
    scenes.firstIndex { $0.id == activeSceneID } ?? 0
  }

  init() {
    let defaults = DefaultConfiguration.bindings()
    var needsSave = false
    var migratesShortcuts = false

    scenes = [MacroPadScene(id: UUID(), keys: defaults)]
    activeSceneID = scenes[0].id

    switch ConfigurationFile.load(configURL, decode: LoadedConfiguration.decode) {
    case .missing:
      break
    case .loaded(.current(let saved)):
      needsSave = (saved.version ?? 1) < 3
      let loadedScenes = saved.migratedScenes()
      if !loadedScenes.isEmpty {
        scenes = loadedScenes
        activeSceneID =
          scenes.contains { $0.id == saved.activeSceneID }
          ? saved.activeSceneID : scenes[0].id
      }
      migratesShortcuts = (saved.version ?? 1) < 2
    case .loaded(.legacy(let saved)):
      scenes[0].keys = DefaultConfiguration.merging(saved, into: defaults)
      migratesShortcuts = true
      needsSave = true
    case .malformed(let recovery):
      configurationRecoveries.append(recovery)
      needsSave = true
    }

    switch ConfigurationFile.load(
      appearanceURL, decode: { try JSONDecoder().decode([String: String].self, from: $0) })
    {
    case .missing:
      break
    case .loaded(let settings):
      if let legacyBackground = settings["background"], scenes[0].backgroundPath == nil {
        scenes[0].backgroundPath = legacyBackground
        needsSave = true
      }
      padFollowMac = settings["followMacBrightness"] == "true"
      displayBrightness = min(100, max(0, Int(settings["brightness"] ?? "80") ?? 80))
    case .malformed(let recovery):
      configurationRecoveries.append(recovery)
      needsSave = true
    }

    // Runs once: afterwards the saved version marks unrecorded shortcuts as explicit.
    if migratesShortcuts {
      for sceneIndex in scenes.indices {
        for keyIndex in scenes[sceneIndex].keys.indices {
          scenes[sceneIndex].keys[keyIndex].migrateRecordedShortcut()
        }
      }
      needsSave = true
    }

    if needsSave {
      save()
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let id = self.recording else { return event }
      if event.keyCode == 53 {
        self.recording = nil
        return nil
      }
      let modifiers = UInt64(
        event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
      if let i = self.scenes[self.activeSceneIndex].keys.firstIndex(where: { $0.id == id })
      {
        self.scenes[self.activeSceneIndex].keys[i].keyCode = event.keyCode
        self.scenes[self.activeSceneIndex].keys[i].modifiers = modifiers
        self.scenes[self.activeSceneIndex].keys[i].recordedShortcut = self.shortcutLabel(event)
      } else {
        self.recording = nil
        self.message = "The control being recorded no longer exists"
        return event
      }
      self.recording = nil
      self.save()
      return nil
    }
    startHID()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.syncPadBrightness() }
    adaptiveTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func shortcutLabel(_ e: NSEvent) -> String {
    let flags = e.modifierFlags
    return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
      + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
      + (e.charactersIgnoringModifiers?.uppercased() ?? "Key \(e.keyCode)")
  }

  func save() {
    do {
      try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !protectedURLs.contains(configURL) {
        let configuration = SavedConfiguration(
          version: SavedConfiguration.currentVersion, bindings: [], scenes: scenes,
          activeSceneID: activeSceneID)
        try JSONEncoder().encode(configuration).write(to: configURL, options: .atomic)
      }
      try saveAppearance()
      refreshDisplay()
      if !protectedURLs.isEmpty {
        message =
          "Changes aren't being saved: fix or move the unreadable configuration file, then restart MacroPad"
      }
    } catch { message = "Could not save: \(error.localizedDescription)" }
  }

  func selectScene(_ id: UUID) {
    guard scenes.contains(where: { $0.id == id }), activeSceneID != id else { return }
    activeSceneID = id
    save()
  }

  func addScene() {
    let keys = DefaultConfiguration.bindings()
    let scene = MacroPadScene(id: UUID(), keys: keys)
    scenes.append(scene)
    activeSceneID = scene.id
    save()
  }

  func duplicateActiveScene() {
    var scene = scenes[activeSceneIndex]
    scene.id = UUID()
    scenes.insert(scene, at: activeSceneIndex + 1)
    activeSceneID = scene.id
    save()
  }

  func applyDialPreset(_ preset: DialPreset, to code: Int) {
    guard let controls = DialPreset.controls(for: code) else { return }
    recording = nil
    for (id, action) in zip(controls, preset.actions) {
      guard let index = scenes[activeSceneIndex].keys.firstIndex(where: { $0.id == id }) else { continue }
      let old = scenes[activeSceneIndex].keys[index]
      var binding = Binding(id: id, name: old.name)
      binding.action = action.name
      scenes[activeSceneIndex].keys[index] = binding
    }
    save()
  }

  func deleteActiveScene() {
    guard scenes.count > 1 else { return }
    let index = activeSceneIndex
    scenes.remove(at: index)
    activeSceneID = scenes[min(index, scenes.count - 1)].id
    save()
  }

  func changeScene(by offset: Int) {
    guard scenes.count > 1 else { return }
    let index = (activeSceneIndex + offset + scenes.count) % scenes.count
    activeSceneID = scenes[index].id
    message = ""
    save()
  }

  private func saveAppearance() throws {
    guard !protectedURLs.contains(appearanceURL) else { return }
    try FileManager.default.createDirectory(
      at: appearanceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let settings = [
      "brightness": String(displayBrightness), "followMacBrightness": String(padFollowMac),
    ]
    try JSONEncoder().encode(settings).write(to: appearanceURL, options: .atomic)
  }

  func syncPadBrightness() {
    guard padFollowMac, let display else { return }
    do {
      let percent = Int((try MacBrightness.level() * 100).rounded())
      guard percent != displayBrightness else { return }
      displayBrightness = percent
      display.setBrightness(percent) {}
    } catch {
      padFollowMac = false
      message = "Adaptive pad brightness stopped: \(error.localizedDescription)"
      try? saveAppearance()
    }
  }

  func execute(_ b: Binding) {
    ActionCatalog.action(named: b.action).perform(b, in: self)
  }

  func report(_ message: String) {
    self.message = message
  }

  func changePadBrightness(by delta: Int) {
    guard let display else {
      message = "Connect the MSD-TWO to change its display brightness"
      return
    }
    padFollowMac = false
    displayBrightness = min(100, max(0, displayBrightness + delta))
    display.setBrightness(displayBrightness) { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        do {
          try self.saveAppearance()
          self.message = ""
        } catch { self.message = error.localizedDescription }
      }
    }
  }

  func togglePadFollowMac() throws {
    guard display != nil else {
      throw ActionError.failed("Connect the MSD-TWO to use adaptive brightness")
    }
    if !padFollowMac { _ = try MacBrightness.level() }
    padFollowMac.toggle()
    syncPadBrightness()
    try saveAppearance()
  }

  func requestAccessibilityAccess() -> Bool {
    guard AXIsProcessTrusted() else {
      message = "Allow MacroPad in System Settings → Privacy & Security → Accessibility"
      let options =
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      return false
    }
    return true
  }
}
