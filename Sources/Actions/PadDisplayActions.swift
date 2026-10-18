import Foundation

/// Steps the MSD-TWO display brightness by 5%, turning off adaptive brightness.
struct PadBrightnessAdjustment: AdjustmentAction {
  static let subject = "MSD-TWO brightness"
  let direction: AdjustmentDirection

  /// Names used before the Mac display actions were added.
  var aliases: [String] { ["Display brightness \(direction == .up ? "up" : "down")"] }
  var symbol: String? { direction == .up ? "sun.max.fill" : "sun.min.fill" }

  func summary(in context: ActionContext) -> String? {
    "Adjusts the MSD-TWO display by 5% per click. Current setting: \(context.displayBrightness)%."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    context.changePadBrightness(by: direction.sign * 5)
  }
}

struct TogglePadAdaptiveBrightnessAction: MacroAction {
  let name = "Toggle MSD-TWO adaptive brightness"
  let symbol: String? = "sun.max.circle"

  func summary(in context: ActionContext) -> String? {
    "Makes the pad follow the Mac display brightness, including automatic adjustments. Currently \(context.padFollowMac ? "on" : "off"). Manual pad brightness changes turn this off."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    do {
      try context.togglePadFollowMac()
      context.report("")
    } catch { context.report(error.localizedDescription) }
  }
}
