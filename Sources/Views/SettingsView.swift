import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: Model
  @State private var selected = 0x51

  private var isScreenKey: Bool { (1...6).contains(selected) }

  private var index: Int? {
    model.scenes[model.activeSceneIndex].keys.firstIndex { $0.id == selected }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 22) {
          Picker(
            "Scene",
            selection: SwiftUI.Binding(
              get: { model.activeSceneID }, set: { model.selectScene($0) })
          ) {
            ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
              Text("Scene \(index + 1)").tag(scene.id)
            }
          }
          Text("YOUR DEVICE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(
            .secondary)
          DeviceView(model: model, selected: $selected)
          Label("Click a button or dial to configure it", systemImage: "cursorarrow.rays")
            .font(.callout).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            Text("Scene background").font(.caption).foregroundStyle(.secondary)
            HStack {
              if let path = model.scenes[model.activeSceneIndex].backgroundPath,
                let image = NSImage(contentsOfFile: path)
              {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 52, height: 39)
                  .clipped()
              } else {
                Rectangle().fill(.black).frame(width: 52, height: 39).overlay(
                  Rectangle().stroke(.gray.opacity(0.3)))
              }
              Button("Black") {
                model.scenes[model.activeSceneIndex].backgroundPath = nil
                model.save()
              }
              Button("Image…") { model.chooseArtwork(for: nil, search: false) }
              Button("Search…") { model.chooseArtwork(for: nil, search: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .modifier(ControlDropTarget(model: model, key: nil))
          .help("Drop an image to set this scene's background")
          Spacer()
          HStack {
            Button {
              model.addScene()
            } label: {
              Label("Add scene", systemImage: "plus")
            }
            .help("Add scene")
            Button {
              model.duplicateActiveScene()
            } label: {
              Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .help("Duplicate current scene")
            Button {
              model.deleteActiveScene()
            } label: {
              Label("Remove scene", systemImage: "minus")
            }
            .help("Delete current scene")
            .disabled(model.scenes.count <= 1)
          }
        }.padding(26).frame(width: 480)
        Divider()
        VStack(alignment: .leading, spacing: 20) {
          ScrollView {
            if let i = index {
              VStack(alignment: .leading, spacing: 20) { editor(i) }.frame(
                maxWidth: .infinity, alignment: .leading)
            }
          }
          Spacer()
        }.padding(26).frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack {
        Text(model.message).lineLimit(2).textSelection(.enabled)
        Spacer()
        Label("Saved automatically", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      }.font(.caption).padding(16)
    }.frame(minWidth: 860, minHeight: 650)
      .onChange(
        of: model.scenes.map {
          "\($0.id)|"
            + $0.keys.map { "\($0.action)|\($0.argument)|\($0.imagePath ?? "")" }
            .joined(separator: ";")
        }.joined(separator: "\n")
      ) {
        model.save()
      }
      .onChange(of: selected) { model.recording = nil }
      .onChange(of: model.activeSceneID) { model.recording = nil }
  }

  @ViewBuilder private func editor(_ i: Int) -> some View {
    let binding: SwiftUI.Binding<Binding> =
      $model.scenes[model.activeSceneIndex].keys[i]
    let item = binding.wrappedValue
    Text(item.name).font(.title2.weight(.semibold))
    if isScreenKey {
      HStack(spacing: 12) {
        if let image = model.keyPreview(item) {
          Image(nsImage: image).resizable().scaledToFit().frame(width: 60, height: 60).background(
            .black)
        } else {
          Rectangle().fill(.black).frame(width: 60, height: 60)
        }
        VStack(alignment: .leading) {
          Text(item.imagePath == nil ? "Automatic icon" : "Custom icon").font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Image…") { model.chooseArtwork(for: selected, search: false) }
            Button("Search…") { model.chooseArtwork(for: selected, search: true) }
          }
          if item.imagePath != nil {
            Button("Use automatic icon") {
              binding.wrappedValue.imagePath = nil
              model.save()
            }
          }
        }
      }
    }
    if [0x35, 0x51, 0x50, 0x33, 0x91, 0x90, 0x34, 0x61, 0x60].contains(selected) {
      Picker("Gesture", selection: SwiftUI.Binding<Int>(get: { selected }, set: { selected = $0 }))
      {
        let group =
          [0x35, 0x51, 0x50].contains(selected)
          ? [0x50, 0x35, 0x51]
          : ([0x33, 0x91, 0x90].contains(selected) ? [0x90, 0x33, 0x91] : [0x60, 0x34, 0x61])
        Text("Turn left").tag(group[0])
        Text("Press").tag(group[1])
        Text("Turn right").tag(group[2])
      }.pickerStyle(.segmented)
    }
    if DialPreset.controls(for: selected) != nil {
      Menu("Set entire dial…") {
        DialPresetMenu(model: model, code: selected)
      }
      Text("Assigns turn left, press, and turn right together for this scene.")
        .font(.caption).foregroundStyle(.secondary)
    }
    let action = ActionCatalog.action(named: item.action)
    VStack(alignment: .leading, spacing: 10) {
      Text("ACTION").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
      Menu {
        actionButton(ActionCatalog.none, binding: binding)
        Divider()
        ForEach(ActionCatalog.groups, id: \.name) { group in
          Menu(group.name) {
            ForEach(group.actions, id: \.name) { action in
              actionButton(action, binding: binding)
            }
          }
        }
      } label: {
        Text(item.action)
      }
      .accessibilityLabel("Action")
    }
    action.editor(for: binding, model: model)
    Button {
      model.execute(item)
    } label: {
      Label("Test action", systemImage: "play.fill")
    }.disabled(!action.isReady(item))
  }

  private func actionButton(_ action: any MacroAction, binding: SwiftUI.Binding<Binding>)
    -> some View
  {
    Button {
      binding.wrappedValue.action = action.name
    } label: {
      if binding.wrappedValue.action == action.name {
        Label(action.name, systemImage: "checkmark")
      } else {
        Text(action.name)
      }
    }
  }
}
