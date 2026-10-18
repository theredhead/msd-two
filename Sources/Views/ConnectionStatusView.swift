import SwiftUI

struct ConnectionStatusView: View {
  @ObservedObject var model: Model

  var body: some View {
    Label(model.connected ? "Connected" : "Disconnected", systemImage: "circle.fill")
      .font(.caption)
      .foregroundStyle(model.connected ? .green : .orange)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .fixedSize()
  }
}
