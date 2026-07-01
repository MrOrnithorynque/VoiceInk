---
name: audio-capture
description: Work on VoiceInk's microphone/audio recording — CoreAudioRecorder (AUHAL), Recorder, AudioDeviceManager, device selection/switching, sample-rate/format conversion, audio metering, the onAudioChunk streaming seam, or adding a new mic-style capture source. Use for any change to how raw audio is captured, converted, or written to WAV. (System/per-app audio taps live in the core-audio-capture skill; the multi-source subsystem in conversation-mode.)
---

# Audio capture

Low-level recording lives in **`CoreAudioRecorder.swift`** (raw Core Audio, `@unchecked Sendable`), wrapped by **`Recorder.swift`** (`@MainActor`, meters + device-switch handling), with device enumeration in **`Services/AudioDeviceManager.swift`**.

## How it works today (single source)

1. `VoiceInkEngine.toggleRecord()` picks one output URL `<UUID>.wav` and calls `Recorder.startRecording(toOutputFile:)`.
2. `Recorder` creates a `CoreAudioRecorder`, forwards `onAudioChunk`, and starts it on the serial `audioSetupQueue` (off the main thread to avoid hotkey lag).
3. `CoreAudioRecorder` builds an **AUHAL** unit (`kAudioUnitSubType_HALOutput`), enables input element 1, sets the chosen device via `kAudioOutputUnitProperty_CurrentDevice` — this does **not** change the system default device.
4. The device's native format is read; an input callback renders **Float32** interleaved frames.
5. `convertAndWriteToFile()` mixes all channels to **mono**, resamples to **16 kHz** (linear interpolation), converts to **Int16**, writes via `ExtAudioFile`, and also hands the same PCM `Data` to `onAudioChunk` (used by streaming providers, which expect 16-bit / 16 kHz / mono / little-endian).
6. Meters (`averagePower`/`peakPower`) are computed in the callback under `meterLock`; `Recorder` samples them on a 17 ms timer and publishes a smoothed `AudioMeter`.

`switchDevice(to:)` reconfigures the running unit for a new device mid-recording without closing the WAV file (stop → uninitialize → set device → re-read format → realloc buffers → reinit → start), triggered by the `.audioDeviceSwitchRequired` notification.

## Real-time callback rules (do not violate)

The input callback (`handleInputBuffer` / `convertAndWriteToFile`) runs on the **Core Audio real-time thread**. Inside it:

- **No allocation** — buffers (`renderBuffer`, `conversionBuffer`) are pre-allocated in `configureFormats()` and reused. Keep it that way.
- **No Swift `async`, no `@MainActor` hops, no unbounded locks.** Metering uses a short `NSLock`; anything heavier must go through a lock-free queue / ring buffer.
- **No logging** in the hot path.
- Respect the `requiredSamples <= renderBufferSize` guard; buffer math assumes ≤ 4096 frames/callback.

## Extending to multiple / non-mic sources

Key facts before you start:

- Everything here assumes **one device → one mono WAV**. Multi-source means N capture instances (or an aggregate device) writing N files/channels and producing N `onAudioChunk` streams that must stay **time-aligned** — align on **host time only** (`mHostTime` / `mach_absolute_time()`); different devices have independent clocks, so **never compare `mSampleTime` across devices**. This is already built: see the **conversation-mode** and **core-audio-capture** skills.
- **System / per-app audio is NOT captured here.** `ScreenCaptureService` uses ScreenCaptureKit only for OCR. To capture app/system output on macOS 14.4+ use **Core Audio process taps** (`AudioHardwareCreateProcessTap` + `CATapDescription`, optionally aggregated) or **ScreenCaptureKit audio** (`SCStream` with `capturesAudio`). The app is **not sandboxed** and already has the `screen-capture` entitlement, which helps.
- **Mute conflict:** `Recorder.startRecording` calls `MediaController.muteSystemAudio()` and pauses playback on start (see `Recorder.swift`). If you capture system audio you must *not* mute it — gate that behavior on whether a system-audio source is active.
- Device UIDs vs IDs: `AudioDeviceID`s are not stable across reconnects; persist device **UIDs** (`kAudioDevicePropertyDeviceUID`) for saved multi-source configs and resolve to IDs at record time (as `AudioDeviceManager` does).

## Files

- `CoreAudioRecorder.swift` — AUHAL setup, real-time callback, format conversion, `switchDevice`, device-info helpers.
- `Recorder.swift` — MainActor wrapper, meter timer, `.audioDeviceSwitchRequired` observer, system-mute on start/stop.
- `Services/AudioDeviceManager.swift` / `AudioDeviceConfiguration.swift` — enumerate/select devices, `getCurrentDevice()`, `availableDevices`.
- `Views/Settings/AudioInputSettingsView.swift` — single-mic device-picker UI (the multi-source config UI is separate: `Views/Settings/AudioSourcesSettingsView.swift`, see **conversation-mode**).
