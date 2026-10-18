import SwiftUI
import UniformTypeIdentifiers

/// The clickable MSD-TWO illustration; selecting a control opens its editor.
struct DeviceView: View {
  @ObservedObject var model: Model
  @SwiftUI.Binding var selected: Int

  var body: some View {
    VStack(spacing: 24) {
      HStack(alignment: .top, spacing: 26) {
        VStack(spacing: 10) {
          ForEach(0..<2) { row in
            HStack(spacing: 10) {
              ForEach(0..<3) { col in
                let n = row * 3 + col
                Button {
                  select(n + 1)
                } label: {
                  VStack(spacing: 6) {
                    if let b = model.scenes[model.activeSceneIndex].keys.first(where: {
                      $0.id == n + 1
                    }),
                      let image = model.keyPreview(b)
                    {
                      Image(nsImage: image).resizable().scaledToFit().frame(width: 34, height: 34)
                    } else {
                      Image(systemName: "square.dashed").font(.title3)
                    }
                    Text("\(n + 1)").font(.caption2)
                  }.foregroundStyle(isSelected(n + 1) ? Color.white : Color.gray)
                    .frame(width: 58, height: 64)
                    .background(
                      LinearGradient(
                        colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .topLeading,
                        endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: 7).stroke(
                        isSelected(n + 1) ? Color.accentColor : .white.opacity(0.15),
                        lineWidth: isSelected(n + 1) ? 2 : 1))
                }.buttonStyle(.plain).help("LCD key \(n + 1)")
                  .modifier(ControlDropTarget(model: model, key: n + 1))
              }
            }
          }
        }
        dial(press: 0x35, cw: 0x51, ccw: 0x50, size: 114, name: "Large dial")
      }
      HStack(spacing: 26) {
        HStack(spacing: 17) {
          ForEach([0x25, 0x30, 0x31], id: \.self) { code in
            Button {
              select(code)
            } label: {
              Circle().fill(
                LinearGradient(
                  colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .topLeading,
                  endPoint: .bottomTrailing)
              )
              .frame(width: 51, height: 51)
              .overlay(
                Circle().stroke(
                  isSelected(code) ? Color.accentColor : .white.opacity(0.3),
                  lineWidth: isSelected(code) ? 3 : 1)
              )
              .overlay(Image(systemName: "circle").foregroundStyle(.white.opacity(0.35)))
            }.buttonStyle(.plain).help(model.scenes[model.activeSceneIndex].keys.first { $0.id == code }?.name ?? "Button")
              .modifier(ControlDropTarget(model: model, key: code))
          }
        }.frame(width: 194)
        HStack(spacing: 10) {
          dial(press: 0x33, cw: 0x91, ccw: 0x90, size: 58, name: "Left small dial")
          dial(press: 0x34, cw: 0x61, ccw: 0x60, size: 58, name: "Right small dial")
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .topLeading,
        endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20)
    )
    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
  }

  private func isSelected(_ code: Int) -> Bool { selected == code }

  private func select(_ code: Int) { selected = code }

  private func dial(press: Int, cw: Int, ccw: Int, size: CGFloat, name: String) -> some View {
    VStack(spacing: 8) {
      Button {
        select(press)
      } label: {
        Circle().fill(
          AngularGradient(
            colors: [.gray, Color(white: 0.14), .gray, Color(white: 0.1), .gray], center: .center)
        )
        .frame(width: size, height: size)
        .overlay(
          Circle().stroke(
            isSelected(press) ? Color.accentColor : .white.opacity(0.2),
            lineWidth: isSelected(press) ? 3 : 1)
        )
        .overlay(
          Image(systemName: "hand.tap").font(.system(size: size > 80 ? 22 : 15)).foregroundStyle(
            .white.opacity(0.75)))
      }.buttonStyle(.plain).help("\(name): press")
        .modifier(ControlDropTarget(model: model, key: press))
      HStack(spacing: 6) {
        direction(ccw, symbol: "arrow.counterclockwise", label: "\(name): counterclockwise")
        direction(cw, symbol: "arrow.clockwise", label: "\(name): clockwise")
      }
    }
    .contextMenu { DialPresetMenu(model: model, code: press) }
  }

  private func direction(_ code: Int, symbol: String, label: String) -> some View {
    Button {
      select(code)
    } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        .frame(width: 25, height: 25)
        .foregroundStyle(isSelected(code) ? .white : .white.opacity(0.6))
        .background(
          isSelected(code) ? Color.accentColor : .white.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).help(label).accessibilityLabel(label)
      .modifier(ControlDropTarget(model: model, key: code))
  }
}

/// Accepts a dropped application or image for a control, or for the background when `key` is nil.
struct ControlDropTarget: ViewModifier {
  let model: Model
  let key: Int?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onDrop(
        of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isTargeted
      ) { providers in
        model.acceptDrop(providers, for: key)
      }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
  }
}

struct DialPresetMenu: View {
  @ObservedObject var model: Model
  let code: Int

  var body: some View {
    Text("Set entire dial")
    ForEach(DialPreset.allCases, id: \.self) { preset in
      Button(preset.rawValue) { model.applyDialPreset(preset, to: code) }
    }
  }
}
