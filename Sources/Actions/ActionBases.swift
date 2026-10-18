import AppKit

enum AdjustmentDirection {
  case up
  case down

  var sign: Int { self == .up ? 1 : -1 }
}

/// Base for paired up/down actions that change a level by a fixed step.
protocol AdjustmentAction: MacroAction {
  /// The persisted name is "<subject> up" or "<subject> down".
  static var subject: String { get }
  var direction: AdjustmentDirection { get }
}

extension AdjustmentAction {
  var name: String { "\(Self.subject) \(direction == .up ? "up" : "down")" }
}

/// Base for actions that post synthetic input events, which macOS gates behind Accessibility.
protocol EventPostingAction: MacroAction {}

extension EventPostingAction {
  func post(_ events: [CGEvent], in context: ActionContext) {
    guard context.requestAccessibilityAccess() else { return }
    for event in events {
      event.post(tap: .cghidEventTap)
    }
    context.report("")
  }
}
