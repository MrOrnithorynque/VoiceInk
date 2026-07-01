---
name: transcription-flow
description: Understand or modify VoiceInk's end-to-end recording lifecycle — VoiceInkEngine orchestration, RecordingState, TranscriptionSession (streaming vs file), TranscriptionPipeline (transcribe → filter → format → word-replace → prompt-detect → AI-enhance → save → paste), and how a Transcription is persisted. Use when changing what happens between pressing the hotkey and text appearing in the target app, or when adding data to the saved transcript.
---

# Transcription flow (record → text in your app)

`Whisper/VoiceInkEngine.swift` (`@MainActor`, `ObservableObject`) is the orchestrator. It owns the `Recorder`, generates the recording URL, manages `recordingState`, and runs the pipeline.

## Lifecycle

**Start** (`toggleRecord`, else-branch):
1. Guard a model is selected; `shouldCancelRecording = false`.
2. Create `<UUID>.wav` in `recordingsDirectory` (`…/Application Support/com.prakashjoshipax.VoiceInk/Recordings`), store as `recordedFile`.
3. Buffer early `onAudioChunk` data in an `OSAllocatedUnfairLock` while the session prepares.
4. `recorder.startRecording(toOutputFile:)` → set `recordingState = .recording`.
5. `ActiveWindowService.applyConfiguration(powerModeId:)` applies **PowerMode** (per-app model/prompt/enhancement overrides).
6. If the model supports streaming, `serviceRegistry.createSession(...)` → `session.prepare()` returns the real audio callback; swap `onAudioChunk` to it and flush buffered chunks. Partial transcripts flow to `partialTranscript` (shown live in the recorder).
7. In a detached task: lazy-load the local whisper/Parakeet model and capture clipboard/screen context for enhancement.

**Stop** (`toggleRecord`, recording-branch):
1. `recordingState = .transcribing`; `recorder.stopRecording()`.
2. If not cancelled: load audio duration, insert **one** `Transcription` (SwiftData, status `.pending`), post `.transcriptionCreated`, call `runPipeline`.
3. If cancelled: cancel session, delete the WAV, back to `.idle`.

## The pipeline (`Whisper/TranscriptionPipeline.swift`)

`pipeline.run(...)` does, in order:
1. **Transcribe** — `session.transcribe(audioURL:)` if a streaming session was prepared, else `serviceRegistry.transcribe(audioURL:model:)`. Returns a plain `String`.
2. `TranscriptionOutputFilter.filter` → trim → optional `WhisperTextFormatter.format` (if `IsTextFormattingEnabled`) → `WordReplacementService.applyReplacements`.
3. Populate the `Transcription` (text, duration, model name, timings, PowerMode name/emoji).
4. **Prompt detection** + optional **AI enhancement** (`AIEnhancementService`) → `enhancedText`.
5. Save, paste into the frontmost app (`CursorPaster`/clipboard), dismiss the recorder.

`RecordingState` (`Whisper/RecordingState.swift`) has six cases — `idle, starting, recording, transcribing, enhancing, busy`; the main path is `.idle → .recording → .transcribing → .enhancing → .idle` (`.starting`/`.busy` gate transitions and hotkey re-entrancy). State changes drive the recorder UI via `RecorderUIManager` + the `RecorderStateProvider` protocol (which `VoiceInkEngine` conforms to).

## Where to hook in

- **Add fields to the saved transcript** → edit `Models/Transcription.swift` (SwiftData `@Model`; the transcript store is local — `cloudKitDatabase: .none` in `VoiceInk.swift` — so keep changes additive/optional for safe migration regardless), set them in `TranscriptionPipeline.run` or `VoiceInkEngine`, render in `Views/History/*`.
- **Change post-processing** (new filter/formatter/replacement step) → `TranscriptionPipeline.run`.
- **Multi-source / speaker-labeled output** → **already built** (Conversation Mode): N time-aligned captures (`Services/MultiSource/*`), segments via `SegmentingTranscriptionService`, `TranscriptMerger` interleave, `Transcription.segmentsJSON`/`audioSourcesJSON`, and a dedicated `TranscriptionPipeline.runMultiSource` that skips AI-enhance. See the **conversation-mode** skill before touching any of it.
- **Cancellation** is cooperative via the `shouldCancel` closure — long new steps should check it.

## Key files

`Whisper/VoiceInkEngine.swift`, `Whisper/TranscriptionPipeline.swift`, `Whisper/RecordingState.swift`, `Whisper/RecorderUIManager.swift`, `Services/TranscriptionSession.swift`, `Services/TranscriptionServiceRegistry.swift`, `Models/Transcription.swift`.
