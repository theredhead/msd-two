import AppKit

extension AppDelegate {
  func presentConfigurationRecoveries(_ recoveries: ArraySlice<ConfigurationRecovery>) {
    guard let recovery = recoveries.first else { return }
    let remaining = recoveries.dropFirst()
    let next = { DispatchQueue.main.async { self.presentConfigurationRecoveries(remaining) } }
    let name = recovery.originalURL.lastPathComponent
    let file = recovery.backupURL ?? recovery.originalURL
    let alert = NSAlert()
    alert.alertStyle = .warning
    if let backup = recovery.backupURL {
      alert.messageText = "MacroPad couldn't read “\(name)”"
      alert.informativeText =
        "The file was backed up as “\(backup.lastPathComponent)” and default settings were created in its place.\n\n\(recovery.problem)"
    } else {
      alert.messageText = "MacroPad couldn't read or back up “\(name)”"
      alert.informativeText =
        "The file was left unchanged. MacroPad is using default settings but won't save them until you fix or move the file and restart MacroPad.\n\nRead error: \(recovery.problem)\nBackup error: \(recovery.backupProblem ?? "Unknown")"
    }
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Save a Copy…")
    alert.addButton(withTitle: "Show in Finder")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertSecondButtonReturn:
        DispatchQueue.main.async { self.saveCopy(of: file, completion: next) }
      case .alertThirdButtonReturn:
        NSWorkspace.shared.activateFileViewerSelecting([file])
        next()
      default:
        next()
      }
    }
  }

  private func saveCopy(of file: URL, completion: @escaping () -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = file.lastPathComponent
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let destination = panel.url else {
        completion()
        return
      }
      do {
        try Data(contentsOf: file).write(to: destination, options: .atomic)
        completion()
      } catch {
        DispatchQueue.main.async {
          NSAlert(error: error).beginSheetModal(for: self.window) { _ in completion() }
        }
      }
    }
  }
}
