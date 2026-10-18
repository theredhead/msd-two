import Foundation

/// Switches the whole device to the next or previous scene, wrapping at either end.
struct SceneNavigationAction: MacroAction {
  enum Direction {
    case next
    case previous
  }

  let direction: Direction

  var name: String { direction == .next ? "Next scene" : "Previous scene" }
  var symbol: String? {
    direction == .next ? "arrow.right.square.fill" : "arrow.left.square.fill"
  }

  func summary(in context: ActionContext) -> String? {
    "Cycles through scenes in order and wraps at either end."
  }

  func perform(_ binding: Binding, in context: ActionContext) {
    context.changeScene(by: direction == .next ? 1 : -1)
  }
}
