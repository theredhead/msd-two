import AppKit
import SwiftUI

/// Base for actions that run the binding's argument as a script through a command-line tool.
protocol ScriptAction: MacroAction {
  var executable: String { get }
  func arguments(for script: String) -> [String]
}

extension ScriptAction {
  var symbol: String? { "terminal" }

  /// Waits for the script off the main thread and reports its standard error if it fails.
  func perform(_ binding: Binding, in context: ActionContext) {
    let arguments = arguments(for: binding.argument)
    runInBackground(in: context) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let errorPipe = Pipe()
      process.standardError = errorPipe
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      if process.terminationStatus != 0 {
        throw ActionError.failed(String(data: errorData, encoding: .utf8) ?? "Script failed")
      }
    }
  }

  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView {
    AnyView(
      ScriptEditor(text: binding.argument).frame(minHeight: 180, maxHeight: 260)
        .border(Color.secondary.opacity(0.25)))
  }
}

struct AppleScriptAction: ScriptAction {
  let name = "AppleScript"
  let executable = "/usr/bin/osascript"

  func arguments(for script: String) -> [String] { ["-e", script] }
}

struct ShellScriptAction: ScriptAction {
  let name = "Shell script"
  let executable = "/bin/zsh"

  func arguments(for script: String) -> [String] { ["-c", script] }
}

/// A plain-text code editor with smart substitutions disabled.
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
