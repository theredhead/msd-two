# LCD key investigation

## Observed on MSD-TWO (0B00:1001)

All six LCD key presses toggle the entire display and produce no vendor input reports in current mode. Dials and circular buttons work.

Runtime output probes used 1024-byte output reports, report ID 0:

- `CRT` at offsets 0–2; `CONNECT` at 5–11, periodically: writes succeed; LCD behavior unchanged.
- `CRT` at 0–2; `DIS` at 5–7: writes succeed and user confirms display turns on; next LCD press turns it off.
- `CRT` at 0–2; `MOD` at 5–7; mode byte at offset 10: both ASCII `3` (0x33) and ASCII `2` (0x32), followed by wake and heartbeat, fail to enable LCD key events.

A successful USB write is not a device acknowledgement. No key mapping has been verified for LCD keys.

## Static evidence

Extracted vendor app is under `/private/tmp/msd-package-inspection`; never installed or executed.

Bundled libSDLibrary arm64 disassembly:

- SDDevice::addModeChangedCommand(unsigned char), 0x320a0: constructs CRT / MOD, mode at offset 10.
- SDDevice::addWakeUpScreenPack(), 0x37d6c: constructs CRT / DIS; special LMA branch sets another byte.
- SDDevice::addHeartbeatPack(), 0x36f30: constructs CRT / CONNECT.
- SDDevice::addHandshakePack(), 0x36afc: constructs HAN. Semantics not verified for this model; not sent.

App StreamDock::onDeviceConnected contains a call with 0x32 at 0x1004d2be8, but closer inspection shows this is conditional on device/version checks (including V25 and StreamDock[0108D]). It is NOT established as the startup mode for this specific device. Earlier conversational claim was too broad.

Public Mirabox N3 SDK input codes exactly match our dials/circular buttons and lists LCD codes 1–6. This is evidence of protocol relation, not proof that initialization and image commands apply unchanged.

Next: trace the device-specific connection branch and complete initialization sequence, including version/transport configuration. Avoid further isolated mode guesses or repeated user key tests without stronger evidence.

Sources:
- https://github.com/MiraboxSpace/StreamDock-Device-SDK/blob/main/Python-SDK/src/StreamDock/Devices/StreamDockN3.py
- https://github.com/stevemurr/streamdock (different model, mode 3 and DIS/LIG startup sequence)

## Hardware verification after image upload

User confirmed all six LCD keys report presses after image upload/commit. Numbered 60-pixel images appeared in the correct order. The app initially failed to render its bitmaps (3-channel bitmap context); changed to 4-channel RGBA and checked encoded dimensions.

Shared background: JPEG LOG uploads did not replace the wallpaper. The SDK's setBackgroundBitmap specifies LOG with a 32-bit big-endian length and target 1; N3 uses raw RGB16. A 240×320 RGB565 zero bitmap produced a black shared background. A 500 ms settling interval before uploading key images allowed background and key artwork to appear together. This interval is currently empirical, not an acknowledged completion protocol. Non-black background orientation and RGB565 byte order still need hardware verification.

Tile calibration: 80×80 images showed only top/left borders, consistent with clipping. At 64×64, the outer right border was not visible. A 64×64 test with 3-pixel-inset red top, green right, blue bottom and yellow left edges showed all four edges (user confirmed). Keep 64×64; this does not establish a software off-by-one bug or exact visible panel dimensions. Calibration overlays only run with --calibrate.
