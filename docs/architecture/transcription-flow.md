# Transcription flow

The record → transcribe → enhance → paste lifecycle. `Whisper/VoiceInkEngine.swift` (`@MainActor`) is the central orchestrator: it owns `Recorder`, generates the WAV URL, and drives `Whisper/TranscriptionPipeline.swift` (transcribe → output-filter → format → word-replace → prompt-detect → AI-enhance → save → paste → dismiss). State lives in `Whisper/RecordingState.swift`; panels are managed by `Whisper/RecorderUIManager.swift`; live streaming partials go through `Services/TranscriptionSession.swift`.

## Single-source vs multi-source start

`VoiceInkEngine.toggleRecord()` first attempts `tryStartMultiSource(powerModeId:)` (atomic — on any failure to start, nothing is left running). It falls through to the single-source path unless both gates pass:

- `TwoSourceTranscriptionEnabled` (UserDefaults) is on, and
- the currently selected model has a segmenting service: `serviceRegistry.segmentingService(for: currentModel) != nil`. Conversation Mode is model-agnostic — any `SegmentingTranscriptionService` conformer qualifies (whisper `LocalTranscriptionService` or `ParakeetTranscriptionService` today). The selected model runs once per source WAV and segments are interleaved by timestamp; each file is one role by default, and the opt-in diarization stage (`ConversationDiarizationEnabled`, see conversation-mode.md) further splits non-mic tracks into "Speaker N".

The multi-source path drives `Services/MultiSource/*` directly (it does not use `Recorder`, so it never mutes system audio or pauses playback). On a successful multi-source start with `ConversationDiarizationEnabled` on, `tryStartMultiSource` also fires a detached, non-fatal `SpeakerDiarizationService.prepareModels()` warm-up while recording — the post-stop pipeline is deliberately cache-only and degrades to role labels if the models are missing.

With `CaptionBridgeEnabled` on, a successful multi-source start additionally opens a `CaptionBridgeServer` session in a non-blocking task (listener failure just means no captions arrive), and `handleMultiSourceStop` closes the bracket via `endCaptionSession()` on every exit path. As of M1 the collected events are counted and dropped; the M2 name resolver will consume them (see conversation-mode.md).
