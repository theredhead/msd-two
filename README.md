# MacroPad

Native macOS menu bar companion for Mars Gaming MSD-TWO / HANVON UGEE CS06 (0B00:1001). Uses IOKit HID in userland; no vendor app or driver required.

Build with `tools/build.sh`, then open `.build/MacroPad.app`. Configuration is saved in `~/Library/Application Support/MacroPad/bindings.json`.

Large dial defaults: clockwise raises the current default audio output by 2%, counterclockwise lowers it, and press toggles mute. Core Audio controls depend on the output device exposing writable volume/mute properties; HDMI and some interfaces may not. Errors appear in the configuration window.

Each mapped control supports volume, mute, a recorded key combination, application launch, inline AppleScript (via osascript), or a shell script (via zsh). Shortcut recording captures one combination, not a timed sequence. Keystroke playback requires macOS Accessibility permission. AppleScript controlling other apps may require Automation permission. Scripts run serially and should terminate promptly.

Hardware mappings are in `captures/control-map.md`. Six LCD keys are not mapped yet: they toggle the display and produce no observed input reports. Vendor software has been extracted only into `/private/tmp/msd-package-inspection` for static inspection; it has not been installed or executed. Its library contains handshake, heartbeat, screen wake, brightness and image-transfer methods that still need decoding.

The configuration window presents a clickable device illustration with an action editor for the selected control. Script fields use plain text with smart substitutions disabled and standard clipboard and undo shortcuts. The bundle identifier is `nl.theredhead.msd-two`.

Validation: native executable compiled and ad-hoc signed; device selection visually checked. User confirmed dial volume control, AppleScript execution, and copy/paste. Shortcut playback, application launching, shell scripts, and mute still require end-to-end verification. This is an initial implementation, not a completed device protocol.
