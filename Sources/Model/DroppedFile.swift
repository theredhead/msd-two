import Foundation
import UniformTypeIdentifiers

/// Finder entries can be aliases or symbolic links (notably /Applications/Safari.app).
enum DroppedFile {
  static func resolvedURL(_ url: URL) throws -> URL {
    let resolved = url.resolvingSymlinksInPath()
    if try resolved.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true {
      return try URL(resolvingAliasFileAt: resolved, options: [.withoutUI, .withoutMounting])
        .resolvingSymlinksInPath()
    }
    return resolved
  }

  static func applicationBinding(_ binding: Binding, url: URL) -> Binding {
    var result = binding
    result.action = OpenApplicationAction.name
    result.argument = url.path
    result.imagePath = nil
    return result
  }
}
