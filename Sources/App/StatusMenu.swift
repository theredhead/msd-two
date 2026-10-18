import AppKit
import ServiceManagement

extension AppDelegate: NSMenuDelegate {
  /// Adds the menu bar item with configuration, scene, login and quit commands.
  func installStatusItem() {
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
    menu.addItem(
      withTitle: "About MacroPad…", action: #selector(showAbout), keyEquivalent: ""
    ).target = self
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    status.menu = menu
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

  @objc func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  @objc func quit() { NSApp.terminate(nil) }
}
