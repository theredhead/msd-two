import Foundation

/// Describes a configuration file that could not be loaded and how it was preserved.
struct ConfigurationRecovery: Equatable {
  let originalURL: URL
  /// The preserved copy; nil when the backup failed and the original was left untouched.
  let backupURL: URL?
  let problem: String
  let backupProblem: String?
}

enum ConfigurationLoadResult<Value> {
  case missing
  case loaded(Value)
  case malformed(ConfigurationRecovery)
}

enum ConfigurationFile {
  /// Loads a configuration file, backing it up beside the original when it can't be read or decoded.
  static func load<Value>(
    _ url: URL, date: Date = Date(), fileManager: FileManager = .default,
    decode: (Data) throws -> Value
  ) -> ConfigurationLoadResult<Value> {
    guard fileManager.fileExists(atPath: url.path) else { return .missing }
    do {
      return .loaded(try decode(try Data(contentsOf: url)))
    } catch {
      let problem = error.localizedDescription
      do {
        let backup = try backUp(url, date: date, fileManager: fileManager)
        return .malformed(
          ConfigurationRecovery(
            originalURL: url, backupURL: backup, problem: problem, backupProblem: nil))
      } catch {
        return .malformed(
          ConfigurationRecovery(
            originalURL: url, backupURL: nil, problem: problem,
            backupProblem: error.localizedDescription))
      }
    }
  }

  static func backUp(_ url: URL, date: Date, fileManager: FileManager = .default) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let stem = url.deletingPathExtension().lastPathComponent
    let pathExtension = url.pathExtension
    let directory = url.deletingLastPathComponent()
    var attempt = 1
    var candidate: URL
    repeat {
      let suffix = attempt == 1 ? "" : "-\(attempt)"
      let name = "\(stem).malformed-\(formatter.string(from: date))\(suffix)"
      candidate = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
      attempt += 1
    } while fileManager.fileExists(atPath: candidate.path)
    try fileManager.copyItem(at: url, to: candidate)
    return candidate
  }
}
