import AppKit

/// Track controls for whichever app is playing media.
enum MediaKey: String, CaseIterable, EventPostingAction {
  case previousTrack = "Previous track"
  case playPause = "Play/pause"
  case nextTrack = "Next track"

  var name: String { rawValue }

  var symbol: String? {
    switch self {
    case .previousTrack: return "backward.end.fill"
    case .playPause: return "playpause.fill"
    case .nextTrack: return "forward.end.fill"
    }
  }

  /// MRMediaRemoteCommand values: kMRTogglePlayPause, kMRNextTrack, kMRPreviousTrack.
  var mediaRemoteCommand: UInt32 {
    switch self {
    case .previousTrack: return 5
    case .playPause: return 2
    case .nextTrack: return 4
    }
  }

  /// Sends the command straight to the Now Playing app, as Control Center does.
  /// Unlike posting key events, this needs no Accessibility permission.
  /// Returns false when the private framework is unavailable, so callers can fall back to `events()`.
  func sendToNowPlaying() -> Bool {
    guard let send = MediaRemote.sendCommand else { return false }
    return send(mediaRemoteCommand, nil)
  }

  func summary(in context: ActionContext) -> String? {
    "Controls whichever app is currently playing media, like the Control Center player."
  }

  /// Falls back to media-key events, which need Accessibility, only if MediaRemote is unavailable.
  func perform(_ binding: Binding, in context: ActionContext) {
    if sendToNowPlaying() {
      context.report("")
      return
    }
    do {
      post(try events(), in: context)
    } catch { context.report(error.localizedDescription) }
  }

  private var keyCode: Int {
    switch self {
    case .previousTrack: return 18
    case .playPause: return 16
    case .nextTrack: return 17
    }
  }

  func events() throws -> [CGEvent] {
    try [true, false].map { isDown in
      let state = isDown ? 0xA : 0xB
      guard
        let event = NSEvent.otherEvent(
          with: .systemDefined, location: .zero,
          modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
          timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
          data1: (keyCode << 16) | (state << 8), data2: -1)?.cgEvent?.copy()
      else {
        throw MediaKeyError.eventCreationFailed
      }
      return event
    }
  }
}

enum MediaRemote {
  typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

  static let sendCommand: SendCommand? = {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
      let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
    else { return nil }
    return unsafeBitCast(symbol, to: SendCommand.self)
  }()
}

private enum MediaKeyError: LocalizedError {
  case eventCreationFailed

  var errorDescription: String? {
    "Could not create a media-key event"
  }
}
