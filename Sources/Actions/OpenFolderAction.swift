import AppKit
import SwiftUI

/// Opens the selected directory in Finder, retaining its custom folder icon.
struct OpenFolderAction: MacroAction {
  static let name = "Open folder"
  var name: String { Self.name }

  private func folderURL(for binding: Binding) -> URL? {
    guard !binding.argument.isEmpty else { return nil }
    let path = (binding.argument as NSString).expandingTildeInPath
    guard (path as NSString).isAbsolutePath else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
      values.isDirectory == true, values.isPackage != true
    else { return nil }
    return url
  }

  func isReady(_ binding: Binding) -> Bool { folderURL(for: binding) != nil }

  func icon(for binding: Binding) -> NSImage? {
    if let url = folderURL(for: binding) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "folder", accessibilityDescription: name)
  }

  func artworkKey(for binding: Binding) -> String { binding.argument }

  func perform(_ binding: Binding, in context: ActionContext) {
    guard let url = folderURL(for: binding) else {
      context.report("Choose an existing folder for \(binding.name) first")
      return
    }
    context.report(NSWorkspace.shared.open(url) ? "" : "Could not open folder: \(url.path)")
  }

  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView {
    AnyView(
      Group {
        TextField("/Users/you/Documents", text: binding.argument)
        Button("Choose folder…") {
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          panel.treatsFilePackagesAsDirectories = false
          if let url = folderURL(for: binding.wrappedValue) { panel.directoryURL = url }
          if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue.argument = url.path
            model.save()
          }
        }
        if !isReady(binding.wrappedValue) {
          Text("Choose an existing folder to enable this action.").foregroundStyle(.secondary)
        }
      })
  }
}
