import Foundation

/// Steps the built-in (or primary) Mac display brightness by 5%.
struct MacBrightnessAdjustment: AdjustmentAction {
  static let subject = "Mac display brightness"
  let direction: AdjustmentDirection

  var symbol: String? { direction == .up ? "sun.max.fill" : "sun.min.fill" }

  func summary(in context: ActionContext) -> String? {
    "Adjusts the built-in Mac display (or primary display when no built-in screen is available) by 5% per click."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    do {
      try MacBrightness.change(Float(direction.sign) * 0.05)
      context.syncPadBrightness()
      context.report("")
    } catch { context.report(error.localizedDescription) }
  }
}

struct ToggleMacAutomaticBrightnessAction: MacroAction {
  let name = "Toggle Mac automatic brightness"
  let symbol: String? = "sun.max.circle"

  func summary(in context: ActionContext) -> String? {
    "Toggles the Mac display’s ambient-light brightness adjustment. Requires a supported Apple display."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    do {
      try MacBrightness.toggleAutomatic()
      context.syncPadBrightness()
      context.report("")
    } catch { context.report(error.localizedDescription) }
  }
}
