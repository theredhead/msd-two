import AppKit
import SwiftUI

/// Replays one recorded key combination as synthetic keyboard events.
struct KeystrokeAction: EventPostingAction {
  let name = "Keystroke"
  let symbol: String? = "keyboard"

  func isReady(_ binding: Binding) -> Bool { binding.recordedShortcut != nil }

  func perform(_ binding: Binding, in context: ActionContext) {
    guard isReady(binding) else {
      context.report("Record a keystroke for \(binding.name) first")
      return
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: false)
    else {
      context.report("Could not create keystroke events")
      return
    }
    down.flags = CGEventFlags(rawValue: binding.modifiers)
    up.flags = CGEventFlags(rawValue: binding.modifiers)
    post([down, up], in: context)
  }

  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView {
    AnyView(KeystrokeEditor(binding: binding, model: model))
  }
}

private struct KeystrokeEditor: View {
  @SwiftUI.Binding var binding: Binding
  @ObservedObject var model: Model

  var body: some View {
    Text(binding.recordedShortcut ?? "No keystroke recorded").font(.title.monospaced()).padding(16)
    Button(model.recording == binding.id ? "Press keys… (Esc cancels)" : "Record keystroke") {
      model.recording = binding.id
    }
    Text(
      "Records one key or key combination. For media keys, select a Media & Audio action. Playback requires Accessibility access."
    ).font(.caption).foregroundStyle(.secondary)
  }
}
