---
name: core-audio-capture
description: Capture SYSTEM or PER-APP audio on macOS 14.4+ via Core Audio process taps (CATapDescription → private aggregate device → IOProc → ExtAudioFile) and enumerate audio processes. Use for any work on VoiceInk's SystemAudioTapRecorder, AudioProcessEnumerator, CoreAudioUtils, or CaptureSourceFactory — or when adding a new tap/aggregate/IOProc capture path. This is the hard-won API reference: the exact initializers, gotchas, RT-safety rules, and the signed-build requirement. (For plain microphone/AUHAL capture see the audio-capture skill.)
---

# Core Audio process taps (system + per-app capture)

VoiceInk captures non-microphone audio with **Core Audio process taps** (macOS 14.4+), not
ScreenCaptureKit (SCK re-nags for Screen Recording on every launch; taps are a one-time
Audio-Recording TCC grant — Apple's *AudioCap* sample pattern). The app is **unsandboxed** and
already holds `com.apple.security.device.audio-input` + `NSAudioCaptureUsageDescription`, so
**no new entitlement/TCC prompt** is needed beyond the existing one.

Files: `VoiceInk/Services/MultiSource/SystemAudioTapRecorder.swift` (the tap recorder, both
global and per-app), `CoreAudioUtils.swift` (shared property helpers + PID→process object),
`AudioProcessEnumerator.swift` (list/resolve audio processes), `CaptureSourceFactory.swift`
(builds a tap recorder from an `AudioSourceConfig`).

## The capture chain (what `SystemAudioTapRecorder.setUpTapChain` does)

1. **Build a `CATapDescription`** for the mode:
   - Global (all output minus self): resolve own process object via
     `CoreAudioUtils.translatePIDToProcessObject(getpid())`, then
     `CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])`.
   - Per-app: `CATapDescription(stereoMixdownOfProcesses: targetProcessObjects)`.
   - Set `.isPrivate = true`, `.muteBehavior = CATapMuteBehavior.unmuted`, `.uuid = UUID()`.
2. `AudioHardwareCreateProcessTap(desc, &tapID)`; read its native format from
   `kAudioTapPropertyFormat`.
3. Resolve the **default output device UID** (`kAudioHardwarePropertyDefaultSystemOutputDevice`
   → `kAudioDevicePropertyDeviceUID`) — the aggregate's **clock anchor**.
4. `AudioHardwareCreateAggregateDevice` with a private aggregate dict:
   `kAudioAggregateDeviceMainSubDeviceKey` = output UID, `…IsPrivateKey` = true,
   `…TapAutoStartKey` = true, `…TapListKey` = `[{SubTapUIDKey: tap.uuid.uuidString,
   SubTapDriftCompensationKey: true}]`.
5. **Output file:** `ExtAudioFileCreateWithURL(kAudioFileWAVEType, fileFormat=16k/mono/Int16)`,
   then set `kExtAudioFileProperty_ClientDataFormat` = the **tap's native format**. ExtAudioFile
   then does SRC + downmix + Int16 conversion on write — **do not hand-roll resampling**.
6. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.
7. **Teardown order (strict):** `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
   `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

## API gotchas (each cost a build cycle to find)

- **Process array is `[AudioObjectID]`, NOT `[NSNumber]`** — `CATapDescription(stereoGlobalTap…: [selfObject])` where `selfObject: AudioObjectID`. Passing `NSNumber` fails to type-check.
- **`CATapMuteBehavior.unmuted` must be qualified** (`.unmuted` alone can't infer the base).
- **Availability is enforced by the C function, not the Swift init.** `CATapDescription(stereoMixdownOfProcesses:)` compiles below 14.2 and fails only at `AudioHardwareCreateProcessTap` (`@14.2`). So the `.app`/tap paths **MUST** be wrapped in `#available(macOS 14.4, *)` in `CaptureSourceFactory` — do not rely on the type-checker.
- **Property reads that return `noErr` + a sentinel are misses, not errors:** `translatePIDToProcessObject` / `TranslateUIDToDevice` return `noErr` + `kAudioObjectUnknown`/`0` for a stale PID/UID — check the value, not just the status.

## Real-time IOProc rules

The IOProc block runs on a Core Audio RT thread. In `SystemAudioTapRecorder` it captures a
`TapWriter` (a `final class … @unchecked Sendable`), **never `self`**. Inside the block: only a
short `OSAllocatedUnfairLock` (mirroring the existing `CoreAudioRecorder` meter precedent),
`ExtAudioFileWrite` (not `AVAudioFile.write`, which allocates), and a first-buffer host-time
capture. No Swift `async`, no `@MainActor`, no allocation, no ObjC message churn. The `fileLock`
guards the `ExtAudioFile` so `close()` can't dispose it under an in-flight write.

## Process enumeration (`AudioProcessEnumerator`)

- `list()` — two-call `AudioObjectGetPropertyDataSize`/`GetPropertyData` on
  `kAudioHardwarePropertyProcessObjectList`, then per object `kAudioProcessPropertyPID` /
  `…BundleID` / `…IsRunningOutput`; join with `NSRunningApplication` by PID for name/icon; drop
  own PID.
- `resolveProcessObjects(forBundleID:)` — re-resolve at **record time** (process objects are
  ephemeral, like device IDs across reconnect). Returns `[]` when the app isn't running/playing
  → the factory throws → the coordinator degrades (drops that source). **Electron/browser
  caveat:** audio routes through renderer helper processes whose bundle ID differs; bundle-ID +
  PID matching may miss them → "captured nothing." Test Chrome/Slack before claiming per-app works.

## Time alignment

Multiple capture streams (mic AUHAL + taps) are unified **only** by host time
(`mHostTime`, fallback `mach_absolute_time()`), never by comparing `mSampleTime` across devices.
The coordinator takes one anchor before starting any source; each source reports its first
buffer's host time → `t0Offset`. See the **conversation-mode** skill.

## The signed-build gotcha (read before "it doesn't work")

`AudioHardwareCreateProcessTap` **succeeds and delivers silence** on an ad-hoc / `make local` /
raw `xcodebuild` build — no error to catch. The Audio-Recording TCC prompt fires only on a
**stably code-signed** binary. So: detect silence by **level + buffers-arrived-within-N-seconds**
(not just OSStatus), and validate the feature only on a signed build (documented in BUILDING.md).
