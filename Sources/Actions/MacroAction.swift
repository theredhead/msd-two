import AppKit
import SwiftUI

/// App services available to an action while it runs. `Model` provides the live implementation.
protocol ActionContext: AnyObject {
  var displayBrightness: Int { get }
  var padFollowMac: Bool { get }

  /// Shows a status message; an empty string clears it. Call on the main queue.
  func report(_ message: String)

  /// Returns whether synthetic input may be posted, prompting for permission if not.
  func requestAccessibilityAccess() -> Bool

  func changeScene(by offset: Int)
  func changePadBrightness(by delta: Int)
  func togglePadFollowMac() throws
  func syncPadBrightness()
}

/// A command a control can trigger. Each family of commands lives in its own file in this folder.
///
/// Protocol extensions supply the shared defaults, so implementations only override what differs.
protocol MacroAction {
  /// Persisted in bindings.json; never change it without keeping the old name in `aliases`.
  var name: String { get }
  var aliases: [String] { get }
  var symbol: String? { get }

  /// Whether the binding has everything it needs to run.
  func isReady(_ binding: Binding) -> Bool
  func icon(for binding: Binding) -> NSImage?

  /// Binding properties, besides the action name, that affect the automatic icon.
  func artworkKey(for binding: Binding) -> String
  func searchTerm(for binding: Binding) -> String
  func summary(in context: ActionContext) -> String?
  func perform(_ binding: Binding, in context: ActionContext)
  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView
}

extension MacroAction {
  var aliases: [String] { [] }
  var symbol: String? { nil }

  func isReady(_ binding: Binding) -> Bool { true }

  func icon(for binding: Binding) -> NSImage? {
    guard let symbol else { return nil }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
  }

  func artworkKey(for binding: Binding) -> String { "" }

  func searchTerm(for binding: Binding) -> String { name + " icon" }

  func summary(in context: ActionContext) -> String? { nil }

  func editor(for binding: SwiftUI.Binding<Binding>, model: Model) -> AnyView {
    guard let summary = summary(in: model) else { return AnyView(EmptyView()) }
    return AnyView(Text(summary).foregroundStyle(.secondary))
  }

  /// Runs blocking work off the main thread, then reports success or the error.
  func runInBackground(in context: ActionContext, _ work: @escaping () throws -> Void) {
    ActionQueue.shared.async {
      do {
        try work()
        DispatchQueue.main.async { context.report("") }
      } catch {
        DispatchQueue.main.async { context.report(error.localizedDescription) }
      }
    }
  }
}

enum ActionQueue {
  static let shared = DispatchQueue(label: "MacroPad.actions")
}

/// The unassigned action.
struct NoAction: MacroAction {
  static let name = "None"

  var name: String { Self.name }

  func isReady(_ binding: Binding) -> Bool { false }

  func searchTerm(for binding: Binding) -> String { "icon" }

  func perform(_ binding: Binding, in context: ActionContext) {}
}

struct ActionGroup {
  let name: String
  let actions: [any MacroAction]
}

/// Every action offered in the action menu, in display order.
enum ActionCatalog {
  static let none = NoAction()

  static let groups: [ActionGroup] = [
    ActionGroup(
      name: "Media & Audio",
      actions: MediaKey.allCases + [
        VolumeAdjustment(direction: .up), VolumeAdjustment(direction: .down), MuteAction(),
      ]),
    ActionGroup(
      name: "Mac Display",
      actions: [
        MacBrightnessAdjustment(direction: .up), MacBrightnessAdjustment(direction: .down),
        ToggleMacAutomaticBrightnessAction(),
      ]),
    ActionGroup(
      name: "MSD-TWO Display",
      actions: [
        PadBrightnessAdjustment(direction: .up), PadBrightnessAdjustment(direction: .down),
        TogglePadAdaptiveBrightnessAction(),
      ]),
    ActionGroup(
      name: "Scenes",
      actions: [
        SceneNavigationAction(direction: .next), SceneNavigationAction(direction: .previous),
      ]
    ),
    ActionGroup(
      name: "Keyboard & Automation",
      actions: [
        KeystrokeAction(), OpenApplicationAction(), AppleScriptAction(), ShellScriptAction(),
      ]),
  ]

  private static let byName: [String: any MacroAction] = {
    var result: [String: any MacroAction] = [none.name: none]
    for action in groups.flatMap(\.actions) {
      for name in [action.name] + action.aliases {
        precondition(result[name] == nil, "Duplicate action name: \(name)")
        result[name] = action
      }
    }
    return result
  }()

  /// Resolves a persisted action name; unknown names behave as no action.
  static func action(named name: String) -> any MacroAction {
    byName[name] ?? none
  }
}

enum ActionError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    if case .failed(let text) = self { return text }
    return nil
  }
}
