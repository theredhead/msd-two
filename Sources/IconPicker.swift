import Cocoa
import UniformTypeIdentifiers
import WebKit

private let iconPickerIntl = IconPickerIntl()

/// Displays a draggable square crop and renders it as a 1024-pixel PNG.
final class SquareCropView: NSView {
  var aspectRatio: CGFloat = 1
  var image: NSImage? {
    didSet {
      zoom = 1
      offset = .zero
      needsDisplay = true
    }
  }

  var zoom: CGFloat = 1 {
    didSet {
      constrain()
      needsDisplay = true
    }
  }

  var offset = CGPoint.zero
  private var dragStart = CGPoint.zero
  private var originalOffset = CGPoint.zero
  override var isFlipped: Bool { false }
  private var imageRect: CGRect {
    guard let image = image, image.size.width > 0, image.size.height > 0 else {
      return .zero
    }

    let scale = max(bounds.width / image.size.width, bounds.height / image.size.height) * zoom
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2 + offset.x,
      y: (bounds.height - size.height) / 2 + offset.y,
      width: size.width, height: size.height)
  }

  private func constrain() {
    let rect = imageRect
    offset.x = min(max(offset.x, -(rect.width - bounds.width) / 2), (rect.width - bounds.width) / 2)
    offset.y = min(
      max(offset.y, -(rect.height - bounds.height) / 2), (rect.height - bounds.height) / 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: bounds).addClip()
    NSColor.black.setFill()
    bounds.fill()
    guard let image = image else {
      let text = iconPickerIntl.selectAnImageToCrop
      text.draw(
        at: CGPoint(x: 35, y: bounds.midY),
        withAttributes: [
          .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 15),
        ])
      return
    }
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = convert(event.locationInWindow, from: nil)
    originalOffset = offset
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    offset = CGPoint(
      x: originalOffset.x + point.x - dragStart.x, y: originalOffset.y + point.y - dragStart.y)
    constrain()
    needsDisplay = true
  }

  /// Renders the current crop, returning nil if no image or bitmap context is available.
  func png() -> Data? {
    guard let image = image,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: Int(1024 / aspectRatio),
        bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = imageRect
    let factor = 1024 / bounds.width
    image.draw(
      in: CGRect(
        x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor,
        height: rect.height * factor), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}

/// Coordinates image search, asynchronous loading, and square-crop selection.
final class IconPicker: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
  private var window: NSWindow!
  private var browser: WKWebView!
  private var searchBrowser: WKWebView!
  private var searchQuery = ""
  private var gridReady = false
  private var isAwaitingResults = false
  private var pendingResults: [String] = []
  private let crop = SquareCropView(frame: NSRect(x: 682, y: 174, width: 300, height: 300))
  private let query = NSTextField(string: "")
  private let status = NSTextField(labelWithString: iconPickerIntl.clickAnImageResultOrChoose)
  private var zoomSlider: NSSlider!
  private var requestID = 0
  private var completion: ((Data) -> Void)?
  var cropClosed: ((Bool) -> Void)?
  var aspectRatio: CGFloat = 1
  private var acceptedCrop = false

  /// Lets local and pasted images use the same crop controls without starting a search.
  func showCrop(image: NSImage, completion: @escaping (Data) -> Void) {
    crop.aspectRatio = aspectRatio
    crop.setFrameSize(NSSize(width: 300, height: 300 / aspectRatio))
    self.completion = completion
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 450),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = iconPickerIntl.chooseDeviceImage
    window.isReleasedWhenClosed = false
    window.delegate = self
    let root = window.contentView!
    crop.frame = NSRect(x: 40, y: 110, width: 300, height: 300 / aspectRatio)
    crop.image = image
    root.addSubview(crop)
    let instruction = NSTextField(labelWithString: "Drag to position the crop.")
    instruction.frame = NSRect(x: 20, y: 418, width: 340, height: 24)
    root.addSubview(instruction)
    zoomSlider = NSSlider(
      value: 1, minValue: 1, maxValue: 4, target: self, action: #selector(zoomChanged(_:)))
    zoomSlider.frame = NSRect(x: 40, y: 70, width: 300, height: 24)
    root.addSubview(zoomSlider)
    let use = NSButton(
      title: iconPickerIntl.useThisCrop, target: self, action: #selector(useCrop(_:)))
    use.bezelStyle = .rounded
    use.frame = NSRect(x: 40, y: 20, width: 300, height: 32)
    root.addSubview(use)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func show(searchName: String, completion: @escaping (Data) -> Void) {
    crop.aspectRatio = aspectRatio
    crop.setFrameSize(NSSize(width: 300, height: 300 / aspectRatio))
    self.completion = completion
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1010, height: 640),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = iconPickerIntl.chooseDeviceImage
    window.isReleasedWhenClosed = false
    window.delegate = self
    let root = window.contentView!
    query.stringValue = iconPickerIntl.initialQuery(searchName: searchName)
    query.frame = NSRect(x: 20, y: 592, width: 520, height: 28)
    query.cell?.sendsActionOnEndEditing = false
    query.target = self
    query.action = #selector(searchImages(_:))
    root.addSubview(query)
    let search = NSButton(
      title: iconPickerIntl.search, target: self, action: #selector(searchImages(_:)))
    search.frame = NSRect(x: 548, y: 590, width: 100, height: 32)
    search.bezelStyle = .rounded
    root.addSubview(search)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(self, name: "iconImage")
    browser = WKWebView(
      frame: NSRect(x: 20, y: 20, width: 628, height: 554), configuration: configuration)
    browser.navigationDelegate = self
    let searchConfiguration = WKWebViewConfiguration()
    searchConfiguration.websiteDataStore = .nonPersistent()
    searchConfiguration.userContentController.add(self, name: "iconResults")
    let script = """
      let previous = '';
      function collectImages() {
          const urls = Array.from(new Set(Array.from(document.images)
              .filter(image => image.naturalWidth >= 80 && image.naturalHeight >= 80)
              .map(image => image.currentSrc || image.src)
              .filter(url => /^(https?:|data:image)/.test(url))));
          const signature = JSON.stringify(urls);
          if (signature === previous) return;
          previous = signature;
          window.webkit.messageHandlers.iconResults.postMessage({
              query: new URL(location.href).searchParams.get('q'), urls: urls
          });
      }
      let pending = null;
      function scheduleCollection() {
          clearTimeout(pending);
          pending = setTimeout(collectImages, 200);
      }
      new MutationObserver(scheduleCollection).observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'srcset']
      });
      document.addEventListener('load', scheduleCollection, true);
      collectImages();
      """
    searchConfiguration.userContentController.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    searchBrowser = WKWebView(frame: browser.bounds, configuration: searchConfiguration)
    searchBrowser.navigationDelegate = self
    root.addSubview(browser)
    root.addSubview(crop)
    let instruction = NSTextField(labelWithString: "Drag to position the crop.")
    instruction.frame = NSRect(x: 682, y: 491, width: 308, height: 32)
    root.addSubview(instruction)
    let zoom = NSSlider(
      value: 1, minValue: 1, maxValue: 4, target: self, action: #selector(zoomChanged(_:)))
    zoomSlider = zoom
    zoom.frame = NSRect(x: 682, y: 133, width: 300, height: 24)
    root.addSubview(zoom)
    let local = NSButton(
      title: iconPickerIntl.chooseLocalImage, target: self, action: #selector(chooseLocal(_:)))
    local.frame = NSRect(x: 682, y: 89, width: 300, height: 32)
    local.bezelStyle = .rounded
    root.addSubview(local)
    let use = NSButton(
      title: iconPickerIntl.useThisCrop, target: self, action: #selector(useCrop(_:)))
    use.frame = NSRect(x: 682, y: 46, width: 300, height: 32)
    use.bezelStyle = .rounded
    root.addSubview(use)
    status.frame = NSRect(x: 682, y: 537, width: 300, height: 40)
    status.lineBreakMode = .byWordWrapping
    root.addSubview(status)
    window.center()
    window.makeKeyAndOrderFront(nil)
    searchImages(nil)
  }

  @objc private func searchImages(_ sender: Any?) {
    var url = URLComponents(string: "https://duckduckgo.com/")!
    url.queryItems = [
      URLQueryItem(name: "q", value: query.stringValue), URLQueryItem(name: "iax", value: "images"),
      URLQueryItem(name: "ia", value: "images"),
    ]
    requestID += 1
    searchQuery = query.stringValue
    gridReady = false
    pendingResults = []
    showResults()
    isAwaitingResults = true
    status.stringValue = iconPickerIntl.searchingDuckduckgoImages
    searchBrowser.load(URLRequest(url: url.url!))
  }

  /// Renders remote URLs as DOM properties, keeping result content out of executable markup.
  private func showResults() {
    let labels = ["searching": iconPickerIntl.searchingForImages]
    let labelsData = try! JSONSerialization.data(withJSONObject: labels)
    let labelsJSON = String(data: labelsData, encoding: .utf8)!
    browser.loadHTMLString(
      """
      <!doctype html><meta name="color-scheme" content="light dark">
      <style>
      body { font: 14px -apple-system; margin: 12px; }
      #grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
      button { padding: 6px; border: 1px solid #8886; border-radius: 8px;
               background: #8881; cursor: pointer; height: 160px; }
      button:hover, button:focus { outline: 3px solid #0788ff; }
      img { width: 100%; height: 100%; object-fit: contain; }
      p { color: #888; line-height: 1.5; }
      </style><div id="grid"></div><p id="empty"></p>
      <script>
      const labels = \(labelsJSON);
      document.getElementById('empty').textContent = labels.searching;
      const displayed = new Set();
      window.addResults = function(urls) {
          for (const result of urls) {
              const url = typeof result === 'string' ? result : result.url;
              if (displayed.has(url)) continue;
              displayed.add(url);
              const button = document.createElement('button');
              button.setAttribute('aria-label', result.label || '');
              const image = document.createElement('img');
              image.src = url;
              image.loading = 'lazy';
              button.appendChild(image);
              button.onclick = () => window.webkit.messageHandlers.iconImage.postMessage(url);
              document.getElementById('grid').appendChild(button);
          }
          document.getElementById('empty').hidden = displayed.size > 0;
      };
      </script>
      """, baseURL: nil)
  }

  private func updateResults() {
    let results = pendingResults.enumerated().map { index, url in
      ["url": url, "label": iconPickerIntl.selectImage(number: index + 1)]
    }
    guard gridReady, let data = try? JSONSerialization.data(withJSONObject: results),
      let json = String(data: data, encoding: .utf8)
    else { return }
    browser.evaluateJavaScript("window.addResults(\(json))", completionHandler: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView === browser {
      gridReady = true
      updateResults()
      return
    }
    searchBrowser.evaluateJavaScript("collectImages()", completionHandler: nil)
    if isAwaitingResults {
      status.stringValue = iconPickerIntl.ifNoImagesAppearTryAnother
    }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code != NSURLErrorCancelled {
      isAwaitingResults = false
      status.stringValue = iconPickerIntl.searchUnavailableTryAgainOrChoose
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    if message.name == "iconResults" {
      guard let result = message.body as? [String: Any],
        result["query"] as? String == searchQuery, let urls = result["urls"] as? [String],
        !urls.isEmpty
      else { return }
      pendingResults = urls
      updateResults()
      if isAwaitingResults {
        isAwaitingResults = false
        status.stringValue = iconPickerIntl.clickAnImageResultOrChoose
      }
      return
    }
    guard let value = message.body as? String else {
      return
    }
    requestID += 1
    let selectedID = requestID
    if value.hasPrefix("data:image"), let part = value.components(separatedBy: ",").last,
      let data = Data(base64Encoded: part), let image = NSImage(data: data)
    {
      isAwaitingResults = false
      crop.image = image
      zoomSlider.doubleValue = 1
      status.stringValue = iconPickerIntl.dragAndZoomThenUseThis
      return
    }
    guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? "") else {
      return
    }
    isAwaitingResults = false
    status.stringValue = iconPickerIntl.loadingSelectedImage
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self = self, self.requestID == selectedID else {
          return
        }
        if let data = data, data.count <= 30 * 1024 * 1024, let image = NSImage(data: data) {
          self.crop.image = image
          self.zoomSlider.doubleValue = 1
          self.status.stringValue = iconPickerIntl.dragAndZoomThenUseThis
        } else {
          self.status.stringValue = iconPickerIntl.couldNotLoadThatImageTry
        }
      }
    }.resume()
  }

  @objc private func zoomChanged(_ sender: NSSlider) {
    crop.zoom = CGFloat(sender.doubleValue)
  }

  @objc private func chooseLocal(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
      return
    }
    requestID += 1
    isAwaitingResults = false
    crop.image = image
    zoomSlider.doubleValue = 1
    status.stringValue = iconPickerIntl.dragAndZoomThenUseThis
  }

  @objc private func useCrop(_ sender: Any?) {
    guard let data = crop.png() else {
      status.stringValue = iconPickerIntl.chooseAnImageFirst
      return
    }
    acceptedCrop = true
    completion?(data)
    window.close()
  }

  func windowWillClose(_ notification: Notification) {
    requestID += 1
    browser?.configuration.userContentController.removeScriptMessageHandler(forName: "iconImage")
    searchBrowser?.stopLoading()
    searchBrowser?.configuration.userContentController.removeScriptMessageHandler(
      forName: "iconResults")
    searchBrowser?.navigationDelegate = nil
    browser?.navigationDelegate = nil
    completion = nil
    let closed = cropClosed
    cropClosed = nil
    closed?(acceptedCrop)
  }
}
