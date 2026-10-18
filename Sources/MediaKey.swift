import AppKit

enum MediaKey: String, CaseIterable {
  case previousTrack = "Previous track"
  case playPause = "Play/pause"
  case nextTrack = "Next track"

  var symbol: String {
    switch self {
    case .previousTrack: return "backward.end.fill"
    case .playPause: return "playpause.fill"
    case .nextTrack: return "forward.end.fill"
    }
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

private enum MediaKeyError: LocalizedError {
  case eventCreationFailed

  var errorDescription: String? {
    "Could not create a media-key event"
  }
}
