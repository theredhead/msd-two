import AppKit
import ApplicationServices
import CoreAudio
import IOKit.hid
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Binding: Codable, Identifiable {
  var id: Int
  var name: String
  var action = "None"
  var argument = ""
  var keyCode: UInt16 = 0
  var modifiers: UInt64 = 0
  /// Display label of the recorded shortcut; nil until one is recorded, since key code 0 is A.
  var recordedShortcut: String?
  var imagePath: String?

  /// Earlier versions stored the shortcut label in `argument`.
  mutating func migrateRecordedShortcut() {
    guard recordedShortcut == nil, action == "Keystroke", !argument.isEmpty else { return }
    recordedShortcut = argument
  }
}

struct MacroPadScene: Codable, Identifiable {
  var id: UUID
  var keys: [Binding]
  var backgroundPath: String? = nil
}

private struct SavedConfiguration: Codable {
  /// Version 2 introduced `Binding.recordedShortcut`; earlier files have no version.
  static let currentVersion = 2

  var version: Int?
  var bindings: [Binding]
  var scenes: [MacroPadScene]
  var activeSceneID: UUID
}

private let actionGroups: [(name: String, actions: [String])] = [
  ("Media & Audio", MediaKey.allCases.map(\.rawValue) + ["Volume up", "Volume down", "Mute"]),
  (
    "Mac Display",
    ["Mac display brightness up", "Mac display brightness down", "Toggle Mac automatic brightness"]
  ),
  (
    "MSD-TWO Display",
    ["MSD-TWO brightness up", "MSD-TWO brightness down", "Toggle MSD-TWO adaptive brightness"]
  ),
  ("Scenes", ["Next scene", "Previous scene"]),
  ("Keyboard & Automation", ["Keystroke", "Open application", "AppleScript", "Shell script"]),
]

final class Model: ObservableObject {
  @Published var repairKeyBorders = true
  @Published var connected = false
  @Published var message = "Waiting for device"
  @Published var recording: Int?
  @Published var bindings: [Binding] = []
  @Published var scenes: [MacroPadScene] = []
  @Published var activeSceneID = UUID()
  @Published var displayBrightness = 80
  @Published var padFollowMac = false
  private var adaptiveTimer: Timer?
  private var imagePicker: IconPicker?
  private var appearanceURL: URL {
    configURL.deletingLastPathComponent().appendingPathComponent("appearance.json")
  }
  private var display: LCDSession?
  private var monitor: Any?
  private var manager: IOHIDManager!
  private var displayDevice: IOHIDDevice?
  private var inputBuffers: [ObjectIdentifier: (buffer: UnsafeMutablePointer<UInt8>, size: Int)] =
    [:]
  private var renderedKeys: [String: [UInt8]] = [:]
  private var renderedBackgrounds: [String: [UInt8]] = [:]
  private var displayRefreshScheduled = false
  private let queue = DispatchQueue(label: "MacroPad.actions")
  private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/MacroPad/bindings.json")

  private(set) var configurationRecoveries: [ConfigurationRecovery] = []

  /// Unreadable files that couldn't be backed up are never overwritten.
  private var protectedURLs: Set<URL> {
    Set(configurationRecoveries.filter { $0.backupURL == nil }.map(\.originalURL))
  }

  var activeSceneIndex: Int {
    scenes.firstIndex { $0.id == activeSceneID } ?? 0
  }

  private enum LoadedConfiguration {
    case current(SavedConfiguration)
    case legacy([Binding])
  }

  private static func decodeConfiguration(_ data: Data) throws -> LoadedConfiguration {
    do {
      return .current(try JSONDecoder().decode(SavedConfiguration.self, from: data))
    } catch {
      if let legacy = try? JSONDecoder().decode([Binding].self, from: data) {
        return .legacy(legacy)
      }
      throw error
    }
  }

  init() {
    let defaults = Self.defaultBindings()
    let defaultKeys = defaults.filter { (1...6).contains($0.id) }
    let defaultControls = defaults.filter { !(1...6).contains($0.id) }
    var needsSave = false
    var migratesShortcuts = false

    bindings = defaultControls
    scenes = [MacroPadScene(id: UUID(), keys: defaultKeys)]
    activeSceneID = scenes[0].id

    switch ConfigurationFile.load(configURL, decode: Self.decodeConfiguration) {
    case .missing:
      break
    case .loaded(.current(let saved)):
      bindings = Self.merging(saved.bindings, into: defaultControls)
      let loadedScenes = saved.scenes.map { scene in
        MacroPadScene(
          id: scene.id,
          keys: Self.merging(scene.keys, into: defaultKeys),
          backgroundPath: scene.backgroundPath)
      }
      if !loadedScenes.isEmpty {
        scenes = loadedScenes
        activeSceneID =
          scenes.contains { $0.id == saved.activeSceneID }
          ? saved.activeSceneID : scenes[0].id
      }
      migratesShortcuts = (saved.version ?? 1) < 2
    case .loaded(.legacy(let saved)):
      bindings = Self.merging(
        saved.filter { !(1...6).contains($0.id) }, into: defaultControls)
      scenes[0].keys = Self.merging(
        saved.filter { (1...6).contains($0.id) }, into: defaultKeys)
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
      for index in bindings.indices {
        bindings[index].migrateRecordedShortcut()
      }
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
      if (1...6).contains(id),
        let i = self.scenes[self.activeSceneIndex].keys.firstIndex(where: { $0.id == id })
      {
        self.scenes[self.activeSceneIndex].keys[i].keyCode = event.keyCode
        self.scenes[self.activeSceneIndex].keys[i].modifiers = modifiers
        self.scenes[self.activeSceneIndex].keys[i].recordedShortcut = self.shortcutLabel(event)
      } else if let i = self.bindings.firstIndex(where: { $0.id == id }) {
        self.bindings[i].keyCode = event.keyCode
        self.bindings[i].modifiers = modifiers
        self.bindings[i].recordedShortcut = self.shortcutLabel(event)
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

  private static func defaultBindings() -> [Binding] {
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
      if code == 0x51 { b.action = "Volume up" }
      if code == 0x50 { b.action = "Volume down" }
      if code == 0x35 { b.action = "Mute" }
      return b
    }
  }

  private static func merging(_ saved: [Binding], into defaults: [Binding]) -> [Binding] {
    defaults.map { fallback in
      saved.first { $0.id == fallback.id } ?? fallback
    }
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
          version: SavedConfiguration.currentVersion, bindings: bindings, scenes: scenes,
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
    let keys = (1...6).map { Binding(id: $0, name: "LCD key \($0)") }
    let scene = MacroPadScene(id: UUID(), keys: keys)
    scenes.append(scene)
    activeSceneID = scene.id
    save()
  }

  func deleteActiveScene() {
    guard scenes.count > 1 else { return }
    let index = activeSceneIndex
    scenes.remove(at: index)
    activeSceneID = scenes[min(index, scenes.count - 1)].id
    save()
  }

  private func changeScene(by offset: Int) {
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

  func keyPreview(_ b: Binding) -> NSImage? {
    if let path = b.imagePath, let image = NSImage(contentsOfFile: path) { return image }
    if b.action == "Open application", !b.argument.isEmpty {
      return NSWorkspace.shared.icon(forFile: b.argument)
    }
    if let mediaKey = MediaKey(rawValue: b.action) {
      return NSImage(systemSymbolName: mediaKey.symbol, accessibilityDescription: b.action)
    }
    let symbol: String
    switch b.action {
    case "Volume up": symbol = "speaker.plus.fill"
    case "Volume down": symbol = "speaker.minus.fill"
    case "Mute": symbol = "speaker.slash.fill"
    case "MSD-TWO brightness up", "Mac display brightness up": symbol = "sun.max.fill"
    case "MSD-TWO brightness down", "Mac display brightness down": symbol = "sun.min.fill"
    case "Toggle MSD-TWO adaptive brightness", "Toggle Mac automatic brightness":
      symbol = "sun.max.circle"
    case "Next scene": symbol = "arrow.right.square.fill"
    case "Previous scene": symbol = "arrow.left.square.fill"
    case "Keystroke": symbol = "keyboard"
    case "AppleScript", "Shell script": symbol = "terminal"
    default: return nil
    }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: b.action)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
  }

  /// Identifies a file's current contents cheaply so cached renders follow external edits.
  private static func fileStamp(_ path: String?) -> String {
    guard let path else { return "-" }
    let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
    return "\(path)@\((date as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
  }

  /// Renders all six keys, or nothing, so a failed tile never shifts the others.
  func keyImages() -> [[UInt8]]? {
    let scene = scenes[activeSceneIndex]
    let backgroundStamp = Self.fileStamp(scene.backgroundPath)
    var wallpaper: NSImage??
    var images: [[UInt8]] = []
    for id in 1...6 {
      guard let b = scene.keys.first(where: { $0.id == id }) else { return nil }
      let source = b.action == "Open application" ? b.argument : ""
      let key = [
        String(id), b.action, source, Self.fileStamp(b.imagePath), backgroundStamp,
      ].joined(separator: "\u{1F}")
      if let cached = renderedKeys[key] {
        images.append(cached)
        continue
      }
      if wallpaper == nil {
        wallpaper = .some(
          scene.backgroundPath.flatMap {
            try? ImageLoading.image(contentsOf: URL(fileURLWithPath: $0))
          })
      }
      guard
        let jpeg = Artwork.jpeg(
          image: keyPreview(b), width: 64, height: 64, label: b.action == "None" ? "" : nil,
          wallpaper: wallpaper ?? nil, keyIndex: id - 1)
      else { return nil }
      if renderedKeys.count >= 256 { renderedKeys.removeAll() }
      renderedKeys[key] = jpeg
      images.append(jpeg)
    }
    return images
  }

  func backgroundImageData() -> [UInt8]? {
    let path = scenes[activeSceneIndex].backgroundPath
    let key = Self.fileStamp(path)
    if let cached = renderedBackgrounds[key] { return cached }
    let image = path.flatMap { try? ImageLoading.image(contentsOf: URL(fileURLWithPath: $0)) }
    let data = Artwork.backgroundRGB565(image: image)
    guard data.count == Artwork.backgroundByteCount else { return nil }
    if renderedBackgrounds.count >= 16 { renderedBackgrounds.removeAll() }
    renderedBackgrounds[key] = data
    return data
  }

  private func displayFrame() -> (images: [[UInt8]], background: [UInt8])? {
    guard let images = keyImages(), let background = backgroundImageData() else {
      message = "Could not render the device artwork; the display was not updated"
      return nil
    }
    return (images, background)
  }

  /// Coalesces bursts of edits and scene changes into one render of the latest state.
  func refreshDisplay() {
    guard display != nil, !displayRefreshScheduled else { return }
    displayRefreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      self.displayRefreshScheduled = false
      guard let display = self.display, let frame = self.displayFrame() else { return }
      display.update(images: frame.images, background: frame.background)
    }
  }

  private func storeArtwork(_ data: Data, for key: Int?, sceneID: UUID) {
    do {
      guard let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) else {
        throw ActionError.failed("The scene being edited no longer exists")
      }
      if let key, !scenes[sceneIndex].keys.contains(where: { $0.id == key }) {
        throw ActionError.failed("The screen button being edited no longer exists")
      }
      let folder = configURL.deletingLastPathComponent().appendingPathComponent("Images")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(UUID().uuidString + ".png")
      try data.write(to: url, options: .atomic)
      if let key, let keyIndex = scenes[sceneIndex].keys.firstIndex(where: { $0.id == key }) {
        scenes[sceneIndex].keys[keyIndex].imagePath = url.path
      } else {
        scenes[sceneIndex].backgroundPath = url.path
      }
      save()
    } catch { message = error.localizedDescription }
  }

  func acceptDrop(_ providers: [NSItemProvider], for key: Int?) -> Bool {
    guard providers.count == 1, let provider = providers.first else {
      message = "Drop one application or image at a time"
      return false
    }
    let sceneID = activeSceneID
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
        [weak self] data, error in
        DispatchQueue.main.async {
          guard let self else { return }
          if let error {
            self.message = "Could not read dropped file: \(error.localizedDescription)"
            return
          }
          guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
            url.isFileURL
          else {
            self.message = "The drop did not contain a local file"
            return
          }
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          do {
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if type?.conforms(to: .applicationBundle) == true {
              guard let key else {
                throw ActionError.failed("Drop an image, not an application, onto the background")
              }
              if (1...6).contains(key),
                let sceneIndex = self.scenes.firstIndex(where: { $0.id == sceneID }),
                let index = self.scenes[sceneIndex].keys.firstIndex(where: { $0.id == key })
              {
                self.scenes[sceneIndex].keys[index].action = "Open application"
                self.scenes[sceneIndex].keys[index].argument = url.path
                self.scenes[sceneIndex].keys[index].imagePath = nil
              } else if let index = self.bindings.firstIndex(where: { $0.id == key }) {
                self.bindings[index].action = "Open application"
                self.bindings[index].argument = url.path
                self.bindings[index].imagePath = nil
              } else {
                throw ActionError.failed("The control being edited no longer exists")
              }
              self.save()
            } else {
              guard type?.conforms(to: .image) == true else {
                throw ActionError.failed("Drop an application or a supported image file")
              }
              let image = try ImageLoading.image(contentsOf: url)
              self.applyDroppedImage(image, for: key, sceneID: sceneID)
            }
          } catch { self.message = error.localizedDescription }
        }
      }
      return true
    }
    guard
      let type = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      })
    else {
      message = "Drop an application or image"
      return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          self.message = "Could not read dropped image: \(error.localizedDescription)"
          return
        }
        guard let data else {
          self.message = "The dropped image could not be read"
          return
        }
        do {
          self.applyDroppedImage(try ImageLoading.image(data: data), for: key, sceneID: sceneID)
        } catch { self.message = error.localizedDescription }
      }
    }
    return true
  }

  private func applyDroppedImage(_ image: NSImage, for key: Int?, sceneID: UUID) {
    guard key == nil || key.map({ (1...6).contains($0) }) == true else {
      message = "Only screen buttons and the background can have custom images"
      return
    }
    guard image.size.width > 0, image.size.height > 0,
      scenes.contains(where: { $0.id == sceneID })
    else {
      message = "The image or target scene is no longer available"
      return
    }
    let aspectRatio = key == nil ? 4.0 / 3.0 : 1
    if !Artwork.requiresCrop(image: image, aspectRatio: aspectRatio) {
      guard let png = Artwork.png(image: image) else {
        message = "Could not convert the dropped image to PNG"
        return
      }
      storeArtwork(png, for: key, sceneID: sceneID)
    } else {
      let picker = makePicker(aspectRatio: aspectRatio)
      picker.showCrop(image: image) { [weak self] data in
        self?.storeArtwork(data, for: key, sceneID: sceneID)
      }
    }
  }

  /// Keeps one artwork window open at a time; a replaced picker can't clear its successor.
  private func makePicker(aspectRatio: CGFloat) -> IconPicker {
    imagePicker?.close()
    let picker = IconPicker()
    picker.aspectRatio = aspectRatio
    imagePicker = picker
    picker.cropClosed = { [weak self, weak picker] _ in
      DispatchQueue.main.async {
        guard let self, let picker, self.imagePicker === picker else { return }
        self.imagePicker = nil
      }
    }
    return picker
  }

  func chooseArtwork(for key: Int?, search: Bool) {
    let targetSceneID = activeSceneID
    let aspectRatio: CGFloat = key == nil ? 4.0 / 3.0 : 1
    let apply: (Data) -> Void = { [weak self] data in
      self?.storeArtwork(data, for: key, sceneID: targetSceneID)
    }
    if search {
      let item = key.flatMap { id -> Binding? in
        if (1...6).contains(id) {
          return scenes.first(where: { $0.id == targetSceneID })?.keys.first { $0.id == id }
        }
        return bindings.first { $0.id == id }
      }
      let term: String
      if let item, item.action == "Open application", !item.argument.isEmpty {
        term =
          URL(fileURLWithPath: item.argument).deletingPathExtension().lastPathComponent + " icon"
      } else {
        term =
          item.map { $0.action == "None" ? "icon" : $0.action + " icon" } ?? "abstract background"
      }
      makePicker(aspectRatio: aspectRatio).show(searchName: term, completion: apply)
    } else {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.image]
      panel.canChooseDirectories = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do {
        let image = try ImageLoading.image(contentsOf: url)
        makePicker(aspectRatio: aspectRatio).showCrop(image: image, completion: apply)
      } catch { message = error.localizedDescription }
    }
  }

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

  private func syncPadBrightness() {
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
    if let mediaKey = MediaKey(rawValue: b.action) {
      if mediaKey.sendToNowPlaying() {
        message = ""
        return
      }
      guard requestAccessibilityAccess() else { return }
      do {
        let events = try mediaKey.events()
        for event in events {
          event.post(tap: .cghidEventTap)
        }
        message = ""
      } catch { message = error.localizedDescription }
      return
    }
    if b.action == "Next scene" {
      changeScene(by: 1)
      return
    }
    if b.action == "Previous scene" {
      changeScene(by: -1)
      return
    }
    if b.action == "Toggle MSD-TWO adaptive brightness" {
      do {
        guard display != nil else {
          throw ActionError.failed("Connect the MSD-TWO to use adaptive brightness")
        }
        if !padFollowMac { _ = try MacBrightness.level() }
        padFollowMac.toggle()
        syncPadBrightness()
        try saveAppearance()
        message = ""
      } catch { message = error.localizedDescription }
      return
    }
    if [
      "Mac display brightness up", "Mac display brightness down", "Toggle Mac automatic brightness",
    ].contains(b.action) {
      do {
        if b.action == "Toggle Mac automatic brightness" {
          try MacBrightness.toggleAutomatic()
        } else {
          try MacBrightness.change(b.action == "Mac display brightness up" ? 0.05 : -0.05)
        }
        syncPadBrightness()
        message = ""
      } catch { message = error.localizedDescription }
      return
    }
    if [
      "MSD-TWO brightness up", "MSD-TWO brightness down", "Display brightness up",
      "Display brightness down",
    ].contains(b.action) {
      guard let display else {
        message = "Connect the MSD-TWO to change its display brightness"
        return
      }
      padFollowMac = false
      displayBrightness = min(100, max(0, displayBrightness + (b.action.hasSuffix(" up") ? 5 : -5)))
      let value = displayBrightness
      display.setBrightness(value) { [weak self] in
        DispatchQueue.main.async {
          guard let self else { return }
          do {
            try self.saveAppearance()
            self.message = ""
          } catch { self.message = error.localizedDescription }
        }
      }
      return
    }
    if b.action == "Keystroke" {
      guard b.recordedShortcut != nil else {
        message = "Record a keystroke for \(b.name) first"
        return
      }
      guard requestAccessibilityAccess() else { return }
      guard let source = CGEventSource(stateID: .hidSystemState),
        let down = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: false)
      else { return }
      down.flags = CGEventFlags(rawValue: b.modifiers)
      up.flags = CGEventFlags(rawValue: b.modifiers)
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      message = ""
      return
    }
    if b.action == "Open application" {
      let url = URL(fileURLWithPath: b.argument)
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
        _, error in
        DispatchQueue.main.async { self.message = error?.localizedDescription ?? "" }
      }
      return
    }
    queue.async {
      do {
        switch b.action {
        case "Volume up": try Audio.changeVolume(0.02)
        case "Volume down": try Audio.changeVolume(-0.02)
        case "Mute": try Audio.toggleMute()
        case "AppleScript", "Shell script":
          let process = Process()
          process.executableURL = URL(
            fileURLWithPath: b.action == "AppleScript" ? "/usr/bin/osascript" : "/bin/zsh")
          process.arguments = b.action == "AppleScript" ? ["-e", b.argument] : ["-c", b.argument]
          let errorPipe = Pipe()
          process.standardError = errorPipe
          process.standardOutput = FileHandle.nullDevice
          try process.run()
          let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          if process.terminationStatus != 0 {
            throw ActionError.failed(String(data: errorData, encoding: .utf8) ?? "Script failed")
          }
        default: break
        }
        DispatchQueue.main.async { self.message = "" }
      } catch { DispatchQueue.main.async { self.message = error.localizedDescription } }
    }
  }

  private func requestAccessibilityAccess() -> Bool {
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
enum ActionError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    if case .failed(let text) = self { return text }
    return nil
  }
}
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

struct ScriptEditor: NSViewRepresentable {
  @SwiftUI.Binding var text: String
  final class Coordinator: NSObject, NSTextViewDelegate {
    var owner: ScriptEditor
    init(_ owner: ScriptEditor) { self.owner = owner }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView else { return }
      owner.text = editor.string
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    let editor = NSTextView()
    editor.isRichText = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editor.textContainerInset = NSSize(width: 8, height: 8)
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isGrammarCheckingEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    editor.isAutomaticDataDetectionEnabled = false
    editor.isAutomaticTextCompletionEnabled = false
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.delegate = context.coordinator
    editor.string = text
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.owner = self
    guard let editor = scroll.documentView as? NSTextView else { return }
    if editor.string != text {
      editor.string = text
      editor.undoManager?.removeAllActions()
    }
  }
}

private struct ControlDropTarget: ViewModifier {
  let model: Model
  let key: Int?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onDrop(
        of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isTargeted
      ) { providers in
        model.acceptDrop(providers, for: key)
      }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
  }
}

struct SettingsView: View {
  @ObservedObject var model: Model
  @State private var selected = 0x51
  private var isScreenKey: Bool { (1...6).contains(selected) }
  private var index: Int? {
    if isScreenKey {
      return model.scenes[model.activeSceneIndex].keys.firstIndex { $0.id == selected }
    }
    return model.bindings.firstIndex { $0.id == selected }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 22) {
          Text("YOUR DEVICE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(
            .secondary)
          device
          Label("Click a button or dial to configure it", systemImage: "cursorarrow.rays")
            .font(.callout).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            Text("Device background").font(.caption).foregroundStyle(.secondary)
            HStack {
              if let path = model.scenes[model.activeSceneIndex].backgroundPath,
                let image = NSImage(contentsOfFile: path)
              {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 52, height: 39)
                  .clipped()
              } else {
                Rectangle().fill(.black).frame(width: 52, height: 39).overlay(
                  Rectangle().stroke(.gray.opacity(0.3)))
              }
              Button("Black") {
                model.scenes[model.activeSceneIndex].backgroundPath = nil
                model.save()
              }
              Button("Image…") { model.chooseArtwork(for: nil, search: false) }
              Button("Search…") { model.chooseArtwork(for: nil, search: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .modifier(ControlDropTarget(model: model, key: nil))
          .help("Drop an image to set this scene's background")
          HStack {
            Picker(
              "Scene",
              selection: SwiftUI.Binding(
                get: { model.activeSceneID }, set: { model.selectScene($0) })
            ) {
              ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                Text("Scene \(index + 1)").tag(scene.id)
              }
            }
            Button {
              model.addScene()
            } label: {
              Image(systemName: "plus").frame(width: 24, height: 24)
            }
            .help("Add scene")
            .frame(width: 28, height: 28)
            Button {
              model.deleteActiveScene()
            } label: {
              Image(systemName: "minus").frame(width: 24, height: 24)
            }
            .help("Delete current scene")
            .disabled(model.scenes.count <= 1)
            .frame(width: 28, height: 28)
          }
          Text("Assign Next scene or Previous scene to a control to switch on the device.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Refresh pressed key only (experimental)", isOn: $model.repairKeyBorders)
            .font(.caption)
            .help(
              "Rewrites only the pressed key image to test whether that resets the firmware border. Release timing is approximate."
            )
          Spacer()
        }.padding(26).frame(width: 480)
        Divider()
        VStack(alignment: .leading, spacing: 20) {
          ScrollView {
            if let i = index {
              VStack(alignment: .leading, spacing: 20) { editor(i) }.frame(
                maxWidth: .infinity, alignment: .leading)
            }
          }
          Spacer()
        }.padding(26).frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack {
        Text(model.message).lineLimit(2).textSelection(.enabled)
        Spacer()
        Label("Saved automatically", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      }.font(.caption).padding(16)
    }.frame(minWidth: 860, minHeight: 650)
      .onChange(of: model.bindings.map { "\($0.action)|\($0.argument)|\($0.imagePath ?? "")" }) {
        model.save()
      }
      .onChange(
        of: model.scenes.map {
          "\($0.id)|"
            + $0.keys.map { "\($0.action)|\($0.argument)|\($0.imagePath ?? "")" }
            .joined(separator: ";")
        }.joined(separator: "\n")
      ) {
        model.save()
      }
      .onChange(of: selected) { model.recording = nil }
      .onChange(of: model.activeSceneID) { model.recording = nil }
  }
  private var device: some View {
    VStack(spacing: 24) {
      HStack(alignment: .top, spacing: 26) {
        VStack(spacing: 10) {
          ForEach(0..<2) { row in
            HStack(spacing: 10) {
              ForEach(0..<3) { col in
                let n = row * 3 + col
                Button {
                  select(n + 1)
                } label: {
                  VStack(spacing: 6) {
                    if let b = model.scenes[model.activeSceneIndex].keys.first(where: {
                      $0.id == n + 1
                    }),
                      let image = model.keyPreview(b)
                    {
                      Image(nsImage: image).resizable().scaledToFit().frame(width: 34, height: 34)
                    } else {
                      Image(systemName: "square.dashed").font(.title3)
                    }
                    Text("\(n + 1)").font(.caption2)
                  }.foregroundStyle(isSelected(n + 1) ? Color.white : Color.gray)
                    .frame(width: 58, height: 64)
                    .background(
                      LinearGradient(
                        colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .topLeading,
                        endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: 7).stroke(
                        isSelected(n + 1) ? Color.accentColor : .white.opacity(0.15),
                        lineWidth: isSelected(n + 1) ? 2 : 1))
                }.buttonStyle(.plain).help("LCD key \(n + 1)")
                  .modifier(ControlDropTarget(model: model, key: n + 1))
              }
            }
          }
        }
        dial(press: 0x35, cw: 0x51, ccw: 0x50, size: 114, name: "Large dial")
      }
      HStack(spacing: 26) {
        HStack(spacing: 17) {
          ForEach([0x25, 0x30, 0x31], id: \.self) { code in
            Button {
              select(code)
            } label: {
              Circle().fill(
                LinearGradient(
                  colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .topLeading,
                  endPoint: .bottomTrailing)
              )
              .frame(width: 51, height: 51)
              .overlay(
                Circle().stroke(
                  isSelected(code) ? Color.accentColor : .white.opacity(0.3),
                  lineWidth: isSelected(code) ? 3 : 1)
              )
              .overlay(Image(systemName: "circle").foregroundStyle(.white.opacity(0.35)))
            }.buttonStyle(.plain).help(model.bindings.first { $0.id == code }?.name ?? "Button")
              .modifier(ControlDropTarget(model: model, key: code))
          }
        }.frame(width: 194)
        HStack(spacing: 10) {
          dial(press: 0x33, cw: 0x91, ccw: 0x90, size: 58, name: "Left small dial")
          dial(press: 0x34, cw: 0x61, ccw: 0x60, size: 58, name: "Right small dial")
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .topLeading,
        endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20)
    )
    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
  }

  private func isSelected(_ code: Int) -> Bool { selected == code }

  private func select(_ code: Int) { selected = code }

  private func dial(press: Int, cw: Int, ccw: Int, size: CGFloat, name: String) -> some View {
    VStack(spacing: 8) {
      Button {
        select(press)
      } label: {
        Circle().fill(
          AngularGradient(
            colors: [.gray, Color(white: 0.14), .gray, Color(white: 0.1), .gray], center: .center)
        )
        .frame(width: size, height: size)
        .overlay(
          Circle().stroke(
            isSelected(press) ? Color.accentColor : .white.opacity(0.2),
            lineWidth: isSelected(press) ? 3 : 1)
        )
        .overlay(
          Image(systemName: "hand.tap").font(.system(size: size > 80 ? 22 : 15)).foregroundStyle(
            .white.opacity(0.75)))
      }.buttonStyle(.plain).help("\(name): press")
        .modifier(ControlDropTarget(model: model, key: press))
      HStack(spacing: 6) {
        direction(ccw, symbol: "arrow.counterclockwise", label: "\(name): counterclockwise")
        direction(cw, symbol: "arrow.clockwise", label: "\(name): clockwise")
      }
    }
  }

  private func direction(_ code: Int, symbol: String, label: String) -> some View {
    Button {
      select(code)
    } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        .frame(width: 25, height: 25)
        .foregroundStyle(isSelected(code) ? .white : .white.opacity(0.6))
        .background(
          isSelected(code) ? Color.accentColor : .white.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).help(label).accessibilityLabel(label)
      .modifier(ControlDropTarget(model: model, key: code))
  }

  @ViewBuilder private func editor(_ i: Int) -> some View {
    let binding: SwiftUI.Binding<Binding> =
      isScreenKey
      ? $model.scenes[model.activeSceneIndex].keys[i]
      : $model.bindings[i]
    let item = binding.wrappedValue
    Text(item.name).font(.title2.weight(.semibold))
    if isScreenKey {
      HStack(spacing: 12) {
        if let image = model.keyPreview(item) {
          Image(nsImage: image).resizable().scaledToFit().frame(width: 60, height: 60).background(
            .black)
        } else {
          Rectangle().fill(.black).frame(width: 60, height: 60)
        }
        VStack(alignment: .leading) {
          Text(item.imagePath == nil ? "Automatic icon" : "Custom icon").font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Image…") { model.chooseArtwork(for: selected, search: false) }
            Button("Search…") { model.chooseArtwork(for: selected, search: true) }
          }
          if item.imagePath != nil {
            Button("Use automatic icon") {
              binding.wrappedValue.imagePath = nil
              model.save()
            }
          }
        }
      }
    }
    if [0x35, 0x51, 0x50, 0x33, 0x91, 0x90, 0x34, 0x61, 0x60].contains(selected) {
      Picker("Gesture", selection: SwiftUI.Binding<Int>(get: { selected }, set: { select($0) })) {
        let group =
          [0x35, 0x51, 0x50].contains(selected)
          ? [0x50, 0x35, 0x51]
          : ([0x33, 0x91, 0x90].contains(selected) ? [0x90, 0x33, 0x91] : [0x60, 0x34, 0x61])
        Text("Turn left").tag(group[0])
        Text("Press").tag(group[1])
        Text("Turn right").tag(group[2])
      }.pickerStyle(.segmented)
    }
    VStack(alignment: .leading, spacing: 10) {
      Text("ACTION").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
      Menu {
        Button {
          binding.wrappedValue.action = "None"
        } label: {
          if item.action == "None" {
            Label("None", systemImage: "checkmark")
          } else {
            Text("None")
          }
        }
        Divider()
        ForEach(actionGroups, id: \.name) { group in
          Menu(group.name) {
            ForEach(group.actions, id: \.self) { action in
              Button {
                binding.wrappedValue.action = action
              } label: {
                if item.action == action {
                  Label(action, systemImage: "checkmark")
                } else {
                  Text(action)
                }
              }
            }
          }
        }
      } label: {
        Text(item.action)
      }
      .accessibilityLabel("Action")
    }
    if item.action == "Keystroke" {
      Text(
        item.recordedShortcut ?? "No keystroke recorded"
      ).font(.title.monospaced()).padding(16)
      Button(model.recording == selected ? "Press keys… (Esc cancels)" : "Record keystroke") {
        model.recording = selected
      }
      Text(
        "Records one key or key combination. For media keys, select a Media & Audio action. Playback requires Accessibility access."
      ).font(
        .caption
      ).foregroundStyle(.secondary)
    } else if ["AppleScript", "Shell script"].contains(item.action) {
      ScriptEditor(text: binding.argument).frame(minHeight: 180, maxHeight: 260).border(
        Color.secondary.opacity(0.25))
    } else if item.action == "Open application" {
      TextField("/Applications/Example.app", text: binding.argument)
      Button("Choose application…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url {
          binding.wrappedValue.argument = url.path
          model.save()
        }
      }
    } else if item.action == "Toggle MSD-TWO adaptive brightness" {
      Text(
        "Makes the pad follow the Mac display brightness, including automatic adjustments. Currently \(model.padFollowMac ? "on" : "off"). Manual pad brightness changes turn this off."
      ).foregroundStyle(.secondary)
    } else if item.action == "Toggle Mac automatic brightness" {
      Text(
        "Toggles the Mac display’s ambient-light brightness adjustment. Requires a supported Apple display."
      ).foregroundStyle(.secondary)
    } else if item.action.hasPrefix("Mac display brightness") {
      Text(
        "Adjusts the built-in Mac display (or primary display when no built-in screen is available) by 5% per click."
      ).foregroundStyle(.secondary)
    } else if item.action.hasPrefix("MSD-TWO brightness") {
      Text(
        "Adjusts the MSD-TWO display by 5% per click. Current setting: \(model.displayBrightness)%."
      ).foregroundStyle(.secondary)
    } else if item.action.hasPrefix("Volume") {
      Text("Adjusts the current audio output by 2% per click.").foregroundStyle(.secondary)
    } else if item.action == "Next scene" || item.action == "Previous scene" {
      Text("Cycles through scenes in order and wraps at either end.").foregroundStyle(.secondary)
    } else if MediaKey(rawValue: item.action) != nil {
      Text("Controls whichever app is currently playing media, like the Control Center player.")
        .foregroundStyle(.secondary)
    }
    Button {
      model.execute(item)
    } label: {
      Label("Test action", systemImage: "play.fill")
    }.disabled(
      item.action == "None" || (item.action == "Keystroke" && item.recordedShortcut == nil))
  }
}
private struct ConnectionStatusView: View {
  @ObservedObject var model: Model

  var body: some View {
    Label(model.connected ? "Connected" : "Disconnected", systemImage: "circle.fill")
      .font(.caption)
      .foregroundStyle(model.connected ? .green : .orange)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .fixedSize()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSToolbarDelegate {
  let model = Model()
  var status: NSStatusItem!
  var window: NSWindow!
  private var launchAtLoginItem: NSMenuItem?
  private let scenesMenu = NSMenu(title: "Scenes")
  private let connectionStatusIdentifier = NSToolbarItem.Identifier("MacroPad.connectionStatus")

  func applicationDidFinishLaunching(_ notification: Notification) {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.image = NSImage(
      systemSymbolName: "dial.medium", accessibilityDescription: "MacroPad")
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(
      withTitle: "Configure MacroPad…", action: #selector(showSettings), keyEquivalent: ","
    ).target = self
    let scenesItem = menu.addItem(withTitle: "Scenes", action: nil, keyEquivalent: "")
    scenesItem.submenu = scenesMenu
    if #available(macOS 13.0, *) {
      let item = menu.addItem(
        withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
      item.target = self
      launchAtLoginItem = item
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    status.menu = menu
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "Quit MacroPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
      item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]
      if key == "Z" { item.keyEquivalent = "z" }
      editMenu.addItem(item)
    }
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    NSApp.mainMenu = mainMenu
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "MacroPad Configuration"
    window.subtitle = "MARS GAMING · MSD-TWO"
    let toolbar = NSToolbar(identifier: "MacroPad.configuration")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(model: model))
    window.contentMinSize = NSSize(width: 860, height: 650)
    window.center()
    showSettings()
    if !model.configurationRecoveries.isEmpty {
      DispatchQueue.main.async {
        self.presentConfigurationRecoveries(self.model.configurationRecoveries[...])
      }
    }
  }

  private func presentConfigurationRecoveries(_ recoveries: ArraySlice<ConfigurationRecovery>) {
    guard let recovery = recoveries.first else { return }
    let remaining = recoveries.dropFirst()
    let next = { DispatchQueue.main.async { self.presentConfigurationRecoveries(remaining) } }
    let name = recovery.originalURL.lastPathComponent
    let file = recovery.backupURL ?? recovery.originalURL
    let alert = NSAlert()
    alert.alertStyle = .warning
    if let backup = recovery.backupURL {
      alert.messageText = "MacroPad couldn't read “\(name)”"
      alert.informativeText =
        "The file was backed up as “\(backup.lastPathComponent)” and default settings were created in its place.\n\n\(recovery.problem)"
    } else {
      alert.messageText = "MacroPad couldn't read or back up “\(name)”"
      alert.informativeText =
        "The file was left unchanged. MacroPad is using default settings but won't save them until you fix or move the file and restart MacroPad.\n\nRead error: \(recovery.problem)\nBackup error: \(recovery.backupProblem ?? "Unknown")"
    }
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Save a Copy…")
    alert.addButton(withTitle: "Show in Finder")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertSecondButtonReturn:
        DispatchQueue.main.async { self.saveCopy(of: file, completion: next) }
      case .alertThirdButtonReturn:
        NSWorkspace.shared.activateFileViewerSelecting([file])
        next()
      default:
        next()
      }
    }
  }

  private func saveCopy(of file: URL, completion: @escaping () -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = file.lastPathComponent
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let destination = panel.url else {
        completion()
        return
      }
      do {
        try Data(contentsOf: file).write(to: destination, options: .atomic)
        completion()
      } catch {
        DispatchQueue.main.async {
          NSAlert(error: error).beginSheetModal(for: self.window) { _ in completion() }
        }
      }
    }
  }

  @objc func showSettings() {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, connectionStatusIdentifier]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, connectionStatusIdentifier]
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard itemIdentifier == connectionStatusIdentifier else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "Connection status"
    item.view = NSHostingView(rootView: ConnectionStatusView(model: model))
    return item
  }

  func menuWillOpen(_ menu: NSMenu) {
    scenesMenu.removeAllItems()
    for (index, scene) in model.scenes.enumerated() {
      let item = scenesMenu.addItem(
        withTitle: "Scene \(index + 1)", action: #selector(selectSceneFromMenu(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = scene.id.uuidString
      item.state = scene.id == model.activeSceneID ? .on : .off
    }
    if #available(macOS 13.0, *) {
      switch SMAppService.mainApp.status {
      case .enabled:
        launchAtLoginItem?.state = .on
        launchAtLoginItem?.title = "Launch at Login"
      case .requiresApproval:
        launchAtLoginItem?.state = .mixed
        launchAtLoginItem?.title = "Launch at Login (Approval Required)"
      default:
        launchAtLoginItem?.state = .off
        launchAtLoginItem?.title = "Launch at Login"
      }
    }
  }

  @objc private func selectSceneFromMenu(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else {
      model.message = "Could not identify the selected scene"
      return
    }
    model.selectScene(id)
  }

  @objc private func toggleLaunchAtLogin() {
    if #available(macOS 13.0, *) {
      do {
        switch SMAppService.mainApp.status {
        case .enabled:
          try SMAppService.mainApp.unregister()
        case .requiresApproval:
          SMAppService.openSystemSettingsLoginItems()
        default:
          try SMAppService.mainApp.register()
          if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
          }
        }
      } catch {
        let alert = NSAlert()
        alert.messageText = "Could not change Launch at Login"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
      }
    }
  }

  @objc func quit() { NSApp.terminate(nil) }
}
@main
struct MacroPadMain {

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}
