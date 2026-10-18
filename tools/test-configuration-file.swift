import Foundation

@main
struct ConfigurationFileChecks {
  static func main() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "macropad-config-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockedDirectory = directory.appendingPathComponent("locked")
    defer {
      try? fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
      try? fileManager.removeItem(at: directory)
    }

    let url = directory.appendingPathComponent("bindings.json")
    let date = Date(timeIntervalSince1970: 0)
    let decode = { (data: Data) in try JSONDecoder().decode([String: Int].self, from: data) }

    guard case .missing = ConfigurationFile.load(url, date: date, decode: decode) else {
      preconditionFailure("Missing file should report missing")
    }
    precondition(try! fileManager.contentsOfDirectory(atPath: directory.path).isEmpty)

    try Data(#"{"a":1}"#.utf8).write(to: url)
    guard case .loaded(let value) = ConfigurationFile.load(url, date: date, decode: decode),
      value == ["a": 1]
    else { preconditionFailure("Valid file should load") }

    let malformed = Data("{ not json".utf8)
    try malformed.write(to: url)
    guard case .malformed(let first) = ConfigurationFile.load(url, date: date, decode: decode),
      let firstBackup = first.backupURL
    else { preconditionFailure("Malformed file should be backed up") }
    precondition(firstBackup.lastPathComponent == "bindings.malformed-19700101T000000Z.json")
    precondition(try! Data(contentsOf: firstBackup) == malformed)
    precondition(try! Data(contentsOf: url) == malformed)
    precondition(first.backupProblem == nil && !first.problem.isEmpty)

    guard case .malformed(let second) = ConfigurationFile.load(url, date: date, decode: decode)
    else { preconditionFailure("Second malformed load should be backed up") }
    precondition(
      second.backupURL?.lastPathComponent == "bindings.malformed-19700101T000000Z-2.json")

    try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
    let lockedURL = lockedDirectory.appendingPathComponent("appearance.json")
    try malformed.write(to: lockedURL)
    try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
    guard
      case .malformed(let failed) = ConfigurationFile.load(lockedURL, date: date, decode: decode)
    else { preconditionFailure("Unbackupable file should still report malformed") }
    precondition(failed.backupURL == nil && failed.backupProblem != nil)
    precondition(try! Data(contentsOf: lockedURL) == malformed)

    print("Configuration file checks passed")
  }
}
