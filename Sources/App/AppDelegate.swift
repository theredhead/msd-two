import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
  let model = Model()
  var status: NSStatusItem!
  var window: NSWindow!
  var launchAtLoginItem: NSMenuItem?
  let scenesMenu = NSMenu(title: "Scenes")
  private let connectionStatusIdentifier = NSToolbarItem.Identifier("MacroPad.connectionStatus")

  func applicationDidFinishLaunching(_ notification: Notification) {
    installStatusItem()
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "About MacroPad…", action: #selector(showAbout), keyEquivalent: ""
    ).target = self
    applicationMenu.addItem(.separator())
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
    // Keep this accessory app's window available when Finder becomes active for a drop.
    window.hidesOnDeactivate = false
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
}
