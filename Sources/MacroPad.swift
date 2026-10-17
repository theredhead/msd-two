import AppKit
import SwiftUI
import IOKit.hid
import CoreAudio
import ApplicationServices

struct Binding: Codable, Identifiable {
    var id: Int
    var name: String
    var action = "None"
    var argument = ""
    var keyCode: UInt16 = 0
    var modifiers: UInt64 = 0
}
let actions = ["None", "Volume up", "Volume down", "Mute", "Keystroke", "Open application", "AppleScript", "Shell script"]

final class Model: ObservableObject {
    @Published var connected = false
    @Published var message = "Waiting for device"
    @Published var recording: Int?
    @Published var bindings: [Binding] = []
    private var monitor: Any?
    private var manager: IOHIDManager!
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private let queue = DispatchQueue(label: "MacroPad.actions")
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacroPad/bindings.json")

    init() {
        let defaults: [(Int, String)] = [(0x51,"Large dial clockwise"),(0x50,"Large dial counterclockwise"),(0x35,"Large dial press"),(0x91,"Left small dial clockwise"),(0x90,"Left small dial counterclockwise"),(0x33,"Left small dial press"),(0x61,"Right small dial clockwise"),(0x60,"Right small dial counterclockwise"),(0x34,"Right small dial press"),(0x25,"Left circular button"),(0x30,"Middle circular button"),(0x31,"Right circular button")]
        bindings = defaults.map { code, name in
            var b = Binding(id: code, name: name)
            if code == 0x51 { b.action = "Volume up" }
            if code == 0x50 { b.action = "Volume down" }
            if code == 0x35 { b.action = "Mute" }
            return b
        }
        if let data = try? Data(contentsOf: configURL), let saved = try? JSONDecoder().decode([Binding].self, from: data) {
            for i in bindings.indices { if let b = saved.first(where: { $0.id == bindings[i].id }) { bindings[i] = b } }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let id = self.recording, let i = self.bindings.firstIndex(where: { $0.id == id }) else { return event }
            if event.keyCode == 53 { self.recording = nil; return nil }
            self.bindings[i].keyCode = event.keyCode
            self.bindings[i].modifiers = UInt64(event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
            self.bindings[i].argument = self.shortcutLabel(event)
            self.recording = nil
            self.save()
            return nil
        }
        startHID()
    }
    func shortcutLabel(_ e: NSEvent) -> String {
        let flags = e.modifierFlags
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (e.charactersIgnoringModifiers?.uppercased() ?? "Key \(e.keyCode)")
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(bindings).write(to: configURL, options: .atomic)
        } catch { message = "Could not save: \(error.localizedDescription)" }
    }
    func startHID() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x0B00, kIOHIDProductIDKey: 0x1001, kIOHIDPrimaryUsagePageKey: 0xFFA0] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context else { return }
            let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess else { return }
            let size = max((IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 512, 512)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            model.buffers.append(buffer)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, result, _, _, _, report, length in
                guard let context, result == kIOReturnSuccess, length >= 10 else { return }
                let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
                guard report[0] == 0x41, report[1] == 0x43, report[2] == 0x4b, report[5] == 0x4f, report[6] == 0x4b else { return }
                model.handle(Int(report[9]))
            }, context)
            model.connected = true
            model.message = "CS06 / MSD-TWO connected"
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let model = Unmanaged<Model>.fromOpaque(context).takeUnretainedValue()
            model.connected = false
            model.message = "Device disconnected"
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        if result != kIOReturnSuccess { message = String(format: "HID access failed: 0x%08x", result) }
    }
    func handle(_ code: Int) {
        guard recording == nil else { return }
        guard let binding = bindings.first(where: { $0.id == code }) else { message = String(format: "Unmapped event: 0x%02x", code); return }
        message = "\(binding.name) → \(binding.action)"
        execute(binding)
    }
    func execute(_ b: Binding) {
        if b.action == "Keystroke" {
            guard AXIsProcessTrusted() else {
                message = "Allow MacroPad in System Settings → Privacy & Security → Accessibility"
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                return
            }
            guard let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: false) else { return }
            down.flags = CGEventFlags(rawValue: b.modifiers)
            up.flags = CGEventFlags(rawValue: b.modifiers)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            message = ""
            return
        }
        if b.action == "Open application" {
            let url = URL(fileURLWithPath: b.argument)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { self.message = error?.localizedDescription ?? "" }
            }
            return
        }
        queue.async {
            do {
                switch b.action {
                case "Volume up": try Audio.changeVolume(0.02)
                case "Volume down": try Audio.changeVolume(-0.02)
                case "Mute": try Audio.toggleMute()
                case "AppleScript", "Shell script":
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: b.action == "AppleScript" ? "/usr/bin/osascript" : "/bin/zsh")
                    process.arguments = b.action == "AppleScript" ? ["-e", b.argument] : ["-c", b.argument]
                    let errorPipe = Pipe()
                    process.standardError = errorPipe
                    process.standardOutput = FileHandle.nullDevice
                    try process.run()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 { throw ActionError.failed(String(data: errorData, encoding: .utf8) ?? "Script failed") }
                default: break
                }
                DispatchQueue.main.async { self.message = "" }
            } catch { DispatchQueue.main.async { self.message = error.localizedDescription } }
        }
    }
}
enum ActionError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}
enum Audio {
    static func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func device() throws -> AudioDeviceID {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var d: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: d))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &d) == noErr, d != 0 else { throw ActionError.failed("No default audio output") }
        return d
    }
    static func writable(_ d: AudioDeviceID, _ a: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &settable) == noErr && settable.boolValue
    }
    static func changeVolume(_ delta: Float32) throws {
        let d = try device()
        var changed = false
        // Prefer the master volume; otherwise adjust available output channels.
        for element: UInt32 in [0,1,2] {
            var a = address(kAudioDevicePropertyVolumeScalar, element)
            guard writable(d, &a) else { continue }
            var v: Float32 = 0; var size: UInt32 = 4
            guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr else { continue }
            v = min(1, max(0, v + delta))
            if AudioObjectSetPropertyData(d, &a, 0, nil, 4, &v) == noErr { changed = true }
            if element == 0 && changed { break }
        }
        guard changed else { throw ActionError.failed("This audio output does not expose software volume control") }
    }
    static func toggleMute() throws {
        let d = try device()
        var a = address(kAudioDevicePropertyMute)
        guard writable(d, &a) else { throw ActionError.failed("This audio output does not expose mute control") }
        var mute: UInt32 = 0; var size: UInt32 = 4
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &mute) == noErr else { throw ActionError.failed("Cannot read mute state") }
        mute = mute == 0 ? 1 : 0
        guard AudioObjectSetPropertyData(d, &a, 0, nil, 4, &mute) == noErr else { throw ActionError.failed("Cannot set mute") }
    }
}

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
        if editor.string != text { editor.string = text; editor.undoManager?.removeAllActions() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var selected = 0x51
    @State private var screen: Int?
    private var index: Int? { model.bindings.firstIndex { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacroPad").font(.system(size: 26, weight: .semibold))
                    Text("MARS GAMING · MSD-TWO").font(.caption).tracking(2).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.connected ? "Connected" : "Disconnected", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(model.connected ? .green : .orange)
                    .padding(9).background(.primary.opacity(0.04), in: Capsule())
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("YOUR DEVICE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    device
                    Label("Click a button or dial to configure it", systemImage: "cursorarrow.rays")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(26).frame(width: 480)
                Divider()
                VStack(alignment: .leading, spacing: 20) {
                    if let screen {
                        Text("LCD key \(screen + 1)").font(.title2.weight(.semibold))
                        Label("Mapping unavailable", systemImage: "display").foregroundStyle(.secondary)
                        Text("These six keys currently toggle the display. Individual key events and image configuration are still being investigated.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if let i = index {
                        editor(i)
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
        }.frame(minWidth: 860, minHeight: 550)
        .onChange(of: model.bindings.map { "\($0.action)|\($0.argument)" }) { model.save() }
        .onChange(of: selected) { model.recording = nil }
        .onChange(of: screen) { model.recording = nil }
    }
    private var device: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 10) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 10) {
                            ForEach(0..<3) { col in
                                let n = row * 3 + col
                                Button { screen = n } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: "square.dashed").font(.title3)
                                        Text("\(n + 1)").font(.caption2)
                                    }.foregroundStyle(screen == n ? Color.white : Color.gray)
                                        .frame(width: 58, height: 64)
                                        .background(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(screen == n ? Color.accentColor : .white.opacity(0.15), lineWidth: screen == n ? 2 : 1))
                                }.buttonStyle(.plain).help("LCD key \(n + 1) — mapping pending")
                            }
                        }
                    }
                }
                dial(press: 0x35, cw: 0x51, ccw: 0x50, size: 114, name: "Large dial")
            }
            HStack(spacing: 26) {
                HStack(spacing: 17) {
                    ForEach([0x25,0x30,0x31], id: \.self) { code in
                        Button { select(code) } label: {
                            Circle().fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 51, height: 51)
                                .overlay(Circle().stroke(isSelected(code) ? Color.accentColor : .white.opacity(0.3), lineWidth: isSelected(code) ? 3 : 1))
                                .overlay(Image(systemName: "circle").foregroundStyle(.white.opacity(0.35)))
                        }.buttonStyle(.plain).help(model.bindings.first { $0.id == code }?.name ?? "Button")
                    }
                }.frame(width: 194)
                HStack(spacing: 10) {
                    dial(press: 0x33, cw: 0x91, ccw: 0x90, size: 58, name: "Left small dial")
                    dial(press: 0x34, cw: 0x61, ccw: 0x60, size: 58, name: "Right small dial")
                }
            }
        }.padding(24)
            .background(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
    }
    private func isSelected(_ code: Int) -> Bool { screen == nil && selected == code }
    private func select(_ code: Int) { screen = nil; selected = code }
    private func dial(press: Int, cw: Int, ccw: Int, size: CGFloat, name: String) -> some View {
        VStack(spacing: 8) {
            Button { select(press) } label: {
                Circle().fill(AngularGradient(colors: [.gray, Color(white: 0.14), .gray, Color(white: 0.1), .gray], center: .center))
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(isSelected(press) ? Color.accentColor : .white.opacity(0.2), lineWidth: isSelected(press) ? 3 : 1))
                    .overlay(Image(systemName: "hand.tap").font(.system(size: size > 80 ? 22 : 15)).foregroundStyle(.white.opacity(0.75)))
            }.buttonStyle(.plain).help("\(name): press")
            HStack(spacing: 6) {
                direction(ccw, symbol: "arrow.counterclockwise", label: "\(name): counterclockwise")
                direction(cw, symbol: "arrow.clockwise", label: "\(name): clockwise")
            }
        }
    }
    private func direction(_ code: Int, symbol: String, label: String) -> some View {
        Button { select(code) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 25)
                .foregroundStyle(isSelected(code) ? .white : .white.opacity(0.6))
                .background(isSelected(code) ? Color.accentColor : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    @ViewBuilder private func editor(_ i: Int) -> some View {
        let binding = $model.bindings[i]
        Text(model.bindings[i].name).font(.title2.weight(.semibold))
        if [0x35,0x51,0x50,0x33,0x91,0x90,0x34,0x61,0x60].contains(selected) {
            Picker("Gesture", selection: SwiftUI.Binding<Int>(get: { selected }, set: { select($0) })) {
                let group = [0x35,0x51,0x50].contains(selected) ? [0x50,0x35,0x51] : ([0x33,0x91,0x90].contains(selected) ? [0x90,0x33,0x91] : [0x60,0x34,0x61])
                Text("Turn left").tag(group[0]); Text("Press").tag(group[1]); Text("Turn right").tag(group[2])
            }.pickerStyle(.segmented)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTION").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            Picker("Action", selection: binding.action) { ForEach(actions, id: \.self) { Text($0) } }.labelsHidden()
        }
        if model.bindings[i].action == "Keystroke" {
            Text(model.bindings[i].argument.isEmpty ? "No keystroke recorded" : model.bindings[i].argument).font(.title.monospaced()).padding(16)
            Button(model.recording == selected ? "Press keys… (Esc cancels)" : "Record keystroke") { model.recording = selected }
            Text("Records one key or key combination. Playback requires Accessibility access.").font(.caption).foregroundStyle(.secondary)
        } else if ["AppleScript", "Shell script"].contains(model.bindings[i].action) {
            ScriptEditor(text: binding.argument).frame(minHeight: 180, maxHeight: 260).border(Color.secondary.opacity(0.25))
        } else if model.bindings[i].action == "Open application" {
            TextField("/Applications/Example.app", text: binding.argument)
            Button("Choose application…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.application]
                if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue.argument = url.path; model.save() }
            }
        } else if model.bindings[i].action.hasPrefix("Volume") {
            Text("Adjusts the current audio output by 2% per click.").foregroundStyle(.secondary)
        }
        Button { model.execute(model.bindings[i]) } label: { Label("Test action", systemImage: "play.fill") }.disabled(model.bindings[i].action == "None")
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var status: NSStatusItem!
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "MacroPad")
        let menu = NSMenu()
        menu.addItem(withTitle: "Configure MacroPad…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        status.menu = menu
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit MacroPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]
            if key == "Z" { item.keyEquivalent = "z" }
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 940,height: 610), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "MacroPad Configuration"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        showSettings()
    }
    @objc func showSettings() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func quit() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
