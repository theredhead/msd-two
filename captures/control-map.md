# CS06 live control mapping

Captured 2026-10-18, Europe/Amsterdam. Device 0x0B00:0x1001, serial 878DFF1A3356.

Vendor HID input reports are 512 bytes, report ID 0. All reports observed so far have prefix `41 43 4b 00 00 4f 4b 00 00`, an event code at zero-based byte offset 9, and zeroes afterward. These are observed event codes; broader protocol semantics remain unknown. No separate release reports observed for dial presses.

| Control | Event code (hex) |
|---|---|
| Large dial clockwise | 51 |
| Large dial counterclockwise | 50 |
| Large dial press | 35 |
| Left small dial clockwise | 91 |
| Left small dial counterclockwise | 90 |
| Left small dial press | 33 |
| Right small dial clockwise | 61 |
| Right small dial counterclockwise | 60 |
| Right small dial press | 34 |
| Left circular button below screen | 25 |
| Middle circular button below screen | 30 |
| Right circular button below screen | 31 |

Both small dials are below the large dial and both can be pressed. Left/right refer to the user's normal view of the device.

The three circular buttons are arranged left, middle, and right below the screen.

Screen controls: user tested all six areas; each toggles the entire display off/on. No vendor reports observed during these tests. Individual screen control mapping is unresolved; no conclusion yet about initialization or operating mode.

Raw data: `session-01.log`. Capture source: `../tools/capture.swift`. Capture sends no output reports.

## LCD breakthrough

After uploading and committing a key image, key 1 produced two discrete reports with code `01` at byte 9 (see `lcd-image.log`). Uploading images is associated with normal key reporting; the exact minimum enabling sequence has not been isolated. App now initializes DIS/LIG, uploads six numbered JPEGs, commits each with STP, and sends CONNECT every five seconds. Key codes 2–6 come from exact-device open-source references and still need individual hardware verification.

The initial probe used NSImage TIFF rendering, which may yield Retina-sized pixels. The app now renders explicit 60×60-pixel bitmaps. Physical placement still needs confirmation.
