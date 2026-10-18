import AppKit
import SwiftUI

/// Launches or activates the application stored in the binding's argument.
struct OpenApplicationAction: MacroAction {
  static let name = "Open application"

  var name: String { Self.name }

  func icon(for binding: Binding) -> NSImage? {
    binding.argument.isEmpty ? nil : NSWorkspace.shared.icon(forFile: binding.argument)
  }

  func artworkKey(for binding: Binding) -> String { binding.argument }

  func searchTerm(for binding: Binding) -> String {
    guard !binding.argument.isEmpty else { return name + " icon" }
    return URL(fileURLWithPath: binding.argument).deletingPathExtension().lastPathComponent
      + " icon"
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    let url = URL(fileURLWithPath: binding.argument)
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      DispatchQueue.main.async { context.report(error?.localizedDescription ?? "") }
    }
  }

  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView {
    AnyView(
      Group {
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
      })
  }
}
