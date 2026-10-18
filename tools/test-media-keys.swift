import AppKit

@main
struct MediaKeyChecks {
  static func main() throws {
    let expected: [(MediaKey, Int)] = [
      (.previousTrack, 18), (.playPause, 16), (.nextTrack, 17),
    ]
    for (key, code) in expected {
      precondition(MediaKey(rawValue: key.rawValue) == key)
      let events = try key.events()
      precondition(events.count == 2)
      for (index, cgEvent) in events.enumerated() {
        guard let event = NSEvent(cgEvent: cgEvent) else {
          preconditionFailure("Media event could not be decoded")
        }
        let state = index == 0 ? 0xA : 0xB
        precondition(event.type == .systemDefined)
        precondition(event.subtype.rawValue == 8)
        precondition(event.data1 == (code << 16) | (state << 8))
        precondition(event.data2 == -1)
        precondition(
          cgEvent.flags.rawValue & 0xFF00 == UInt64(state << 8),
          "Unexpected CGEvent flags: \(cgEvent.flags.rawValue)")
      }
    }
    print("PASS all three media keys: system-defined key-down/key-up event encoding")
    // Resolves the MediaRemote entry point without sending a command or touching playback.
    precondition(MediaRemote.sendCommand != nil, "MRMediaRemoteSendCommand is unavailable")
    precondition(MediaKey.playPause.mediaRemoteCommand == 2)
    precondition(MediaKey.nextTrack.mediaRemoteCommand == 4)
    precondition(MediaKey.previousTrack.mediaRemoteCommand == 5)
    print("PASS MediaRemote: command entry point resolves; commands map to toggle/next/previous")
  }
}
