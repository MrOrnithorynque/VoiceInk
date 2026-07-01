# VoiceInk

Native macOS (14.4+) voice-to-text app. Records the microphone, transcribes locally (whisper.cpp / Parakeet / Apple Speech) or via cloud/streaming providers, optionally AI-enhances the text, then pastes it into the frontmost app. SwiftUI + SwiftData, **not sandboxed**.

## Build / run / test

Building is non-trivial: the app links `whisper.xcframework`, which is built from source. **Always use the Makefile — do not just `xcodebuild` from scratch.** See the **building-voiceink** skill for details.

```bash
make local     # build with ad-hoc signing (no Apple dev cert) → ~/Downloads/VoiceInk.app
make dev       # build + run
make build     # standard Debug build (needs signing)
make run       # launch the built app
```

Tests: `VoiceInkTests/`, `VoiceInkUITests/` (thin — most logic is not unit-tested). Run via Xcode or `xcodebuild ... test`.

## Architecture at a glance

Recording lifecycle (hotkey → text in your app):

```
HotkeyManager / MenuBar
      │ toggleMiniRecorder()
RecorderUIManager ──shows──> MiniRecorder / NotchRecorder panels
      │
VoiceInkEngine (@MainActor, central orchestrator)   ← Whisper/VoiceInkEngine.swift
   toggleRecord():
     start → Recorder.startRecording(toOutputFile: <UUID>.wav)   (one 16kHz mono WAV)
           → optional streaming TranscriptionSession (live partials)
           → ActiveWindowService.applyConfiguration()  (PowerMode per-app settings)
     stop  → insert one Transcription (SwiftData) → TranscriptionPipeline.run()
      │
Recorder (@MainActor)                               ← Recorder.swift
      │  wraps
CoreAudioRecorder (AUHAL, real-time)                ← CoreAudioRecorder.swift
      │  writes 16kHz mono Int16 WAV + fires onAudioChunk(Data)
TranscriptionPipeline.run()                         ← Whisper/TranscriptionPipeline.swift
   transcribe → output-filter → format → word-replace → prompt-detect
             → AI-enhance (optional) → save → paste (CursorPaster) → dismiss
```

### Layers & key files

- **Audio capture** — `CoreAudioRecorder.swift` (AUHAL, single input device, real-time callback, format conversion to 16kHz mono Int16), `Recorder.swift` (MainActor wrapper, meters, device-switch handling), `Services/AudioDeviceManager.swift` (device enumeration/selection), `Views/Settings/AudioInputSettingsView.swift` (device picker UI). → **audio-capture** skill.
- **Transcription** — protocol `Services/TranscriptionService.swift` (`transcribe(audioURL:model:) async throws -> String`), `Services/TranscriptionServiceRegistry.swift` (routes a model to a service), model types in `Models/TranscriptionModel.swift` + declarations in `Models/PredefinedModels.swift`. Batch services: `LocalTranscriptionService` (whisper.cpp), `ParakeetTranscriptionService` (FluidAudio), `NativeAppleTranscriptionService`, `CloudTranscription/*`. Live: `Services/StreamingTranscription/*`. → **add-transcription-provider** skill.
- **Engine / orchestration** — `Whisper/VoiceInkEngine.swift` (owns `Recorder`, generates the WAV URL, drives the pipeline), `Whisper/TranscriptionPipeline.swift`, `Whisper/RecordingState.swift`, `Whisper/RecorderUIManager.swift`, `Services/TranscriptionSession.swift`. → **transcription-flow** skill.
- **whisper.cpp bridge** — `Whisper/LibWhisper.swift`, `Whisper/WhisperModelManager.swift`, `Whisper/VoiceInkEngine+Protocols.swift`.
- **Data / persistence** — `Models/Transcription.swift` (single SwiftData `@Model`: one `text` blob + one `audioFileURL`), history UI in `Views/History/*`. The transcript store is **local** (`cloudKitDatabase: .none` in `VoiceInk.swift`); only the separate **dictionary** store (`VocabularyWord`/`WordReplacement`) is CloudKit-synced.
- **PowerMode** — `PowerMode/*`: per-app / per-URL config that swaps the active model, prompt, and enhancement settings when recording starts.
- **Enhancement** — `Services/AIEnhancement/*` (LLM cleanup via LLMkit), `Services/ScreenCaptureService.swift` (ScreenCaptureKit — used **only for OCR screen context**, not audio).

## Conventions

- **Concurrency**: orchestration/UI classes are `@MainActor` (`VoiceInkEngine`, `Recorder`, `RecorderUIManager`, registry). Hardware setup is offloaded to serial `DispatchQueue`s (`audioSetupQueue`). Real-time audio runs on the Core Audio thread — see the audio-capture skill for its hard rules.
- **Logging**: `Logger(subsystem: "com.prakashjoshipax.voiceink", category: "<Type>")`. Use `privacy: .public` for non-PII values you want visible in Console.
- **Settings**: plain `UserDefaults` string/bool keys (e.g. `lastUsedMicrophoneDeviceID`, `isSystemMuteEnabled`, `IsTextFormattingEnabled`, `TranscriptionPrompt`). No central settings model.
- **Recordings**: `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings/<UUID>.wav`, always 16kHz mono Int16 WAV.
- **Entitlements**: `VoiceInk/VoiceInk.entitlements` (release) and `VoiceInk/VoiceInk.local.entitlements` (used by `make local`; keep both in sync when adding capabilities). App is **not** sandboxed; already holds `device.audio-input` and `screen-capture`.
- **New Swift files** must be added to the Xcode project target (`VoiceInk.xcodeproj`), not just the folder, or they won't compile.

## Gotchas

- The transcription protocol returns a **plain `String`** — there is no timestamp/segment/speaker data anywhere in the model layer today.
- On record start, `Recorder` **mutes system audio** (`MediaController.muteSystemAudio()`) and pauses media playback; it un-mutes on stop. Any feature that *captures* system audio must reconcile with this.
- Streaming is opt-in per model (`TranscriptionServiceRegistry.supportsStreaming`); most models are batch (transcribe a finished WAV file).
- `FluidAudio` (SPM dependency, used for Parakeet) also provides **speaker diarization** — relevant before reaching for a cloud diarizer.

## Skills (`.claude/skills/`)

- **building-voiceink** — build, sign, run, and package the app; the whisper.xcframework dependency.
- **audio-capture** — how Core Audio recording works and the real-time-callback rules; where to touch device/format/multi-source capture.
- **add-transcription-provider** — end-to-end steps to add a new transcription model or provider (batch or streaming).
- **transcription-flow** — the record → transcribe → enhance → paste lifecycle and how to modify it.
- **security-checklist** — VoiceInk-specific security & privacy pass (egress, secrets, AX paste, data-at-rest, prompt injection, entitlements) before shipping.
- **documentation-swift** — Swift doc-comment discipline on edited files; delegates architecture-doc sync to the `docs-updater` agent.
- **changelog** — one-file-per-change developer changelog under `docs/changelog/` (distinct from `appcast.xml` release notes).

## Agents (`.claude/agents/`)

- **inquisitor** — spawn after editing any harness file (skill/agent/CLAUDE.md); verifies every concrete claim against the real code. Report-only.
- **docs-updater** — keeps `docs/architecture/*.md` in sync after Swift edits; docs-only.
