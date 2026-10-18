import AppKit
import UniformTypeIdentifiers

extension Model {
  func keyPreview(_ b: Binding) -> NSImage? {
    if let path = b.imagePath, let image = NSImage(contentsOfFile: path) { return image }
    return ActionCatalog.action(named: b.action).icon(for: b)
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
      let source = ActionCatalog.action(named: b.action).artworkKey(for: b)
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
          image: keyPreview(b), width: 64, height: 64, label: b.action == NoAction.name ? "" : nil,
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

  func displayFrame() -> (images: [[UInt8]], background: [UInt8])? {
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
                self.scenes[sceneIndex].keys[index].action = OpenApplicationAction.name
                self.scenes[sceneIndex].keys[index].argument = url.path
                self.scenes[sceneIndex].keys[index].imagePath = nil
              } else if let index = self.bindings.firstIndex(where: { $0.id == key }) {
                self.bindings[index].action = OpenApplicationAction.name
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
      let term =
        item.map { ActionCatalog.action(named: $0.action).searchTerm(for: $0) }
        ?? "abstract background"
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
}
