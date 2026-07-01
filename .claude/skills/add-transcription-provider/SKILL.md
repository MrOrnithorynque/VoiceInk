---
name: add-transcription-provider
description: Add or modify a transcription model/provider in VoiceInk — a new cloud STT API, a local engine, or a streaming (real-time) provider. Covers the ModelProvider enum, TranscriptionModel structs, PredefinedModels, TranscriptionService protocol, TranscriptionServiceRegistry wiring, and the StreamingTranscriptionProvider pattern. Use when integrating a new speech-to-text backend or changing how a model routes to a service.
---

# Adding a transcription provider

Two paths: **batch** (transcribe a finished WAV file) and **streaming** (send live PCM chunks, get partials). Many providers do both — a streaming model falls back to a batch model when needed.

## Core types

- `Models/TranscriptionModel.swift` — `enum ModelProvider` (`.local`, `.parakeet`, `.groq`, `.elevenLabs`, `.deepgram`, `.mistral`, `.gemini`, `.soniox`, `.custom`, `.nativeApple`) and `protocol TranscriptionModel` (+ concrete structs `NativeAppleModel`, `ParakeetModel`, `CloudModel`, …).
- `Models/PredefinedModels.swift` — `enum PredefinedModels` with `static var models: [any TranscriptionModel]`; every selectable model is declared here.
- `Services/TranscriptionService.swift` — `protocol TranscriptionService { func transcribe(audioURL:model:) async throws -> String }`.
- `Services/TranscriptionServiceRegistry.swift` — routes a `ModelProvider` to a concrete service and creates streaming/file sessions.

## Add a BATCH provider

1. **Declare the model(s)** in `PredefinedModels.models` with the right `provider` and `name`.
2. If it's an OpenAI-compatible HTTP API, you likely need **no new service** — `CloudTranscriptionService` (`Services/CloudTranscription/*`) is the `default` route in `TranscriptionServiceRegistry.service(for:)`. Add config there (`CustomModelManager` / `OpenAICompatibleTranscriptionService`) and an API-key entry via `APIKeyManager` / `KeychainService`.
3. For a genuinely new engine, create `Services/YourTranscriptionService.swift` conforming to `TranscriptionService`, add a `lazy` instance in `TranscriptionServiceRegistry`, and a `case` in `service(for:)`.
4. Add API-key UI/storage if needed and expose the model in the model-selection settings UI.

## Add a STREAMING provider

Streaming providers implement `Services/StreamingTranscription/StreamingTranscriptionProvider.swift`:

```swift
protocol StreamingTranscriptionProvider: AnyObject {
    func connect(model: any TranscriptionModel, language: String?) async throws
    func sendAudioChunk(_ data: Data) async throws   // 16-bit, 16kHz, mono, little-endian
    func commit() async throws
    func disconnect() async
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { get } // .sessionStarted/.partial/.committed/.error
}
```

Steps:

1. Create `Services/StreamingTranscription/YourStreamingProvider.swift` implementing the protocol (open a WebSocket in `connect`, push PCM in `sendAudioChunk`, emit events).
2. Register it in `StreamingTranscriptionService.createProvider(for:)` — add a `case model.provider`.
3. Mark the model streaming-capable in `TranscriptionServiceRegistry.supportsStreaming(model:)` (usually gated on exact model `name`).
4. If the streaming model needs a batch fallback (used when a live session can't run), map it in `TranscriptionServiceRegistry.batchFallbackModel(for:)`.

The audio bytes come from `CoreAudioRecorder`'s `onAudioChunk` → `VoiceInkEngine` wires the session's callback (see the **transcription-flow** skill). The PCM format is already 16 kHz / mono / Int16 — do not resample again.

## Timestamps / diarization

The base protocol returns a **plain `String`**, but segment timestamps ARE plumbed through a
separate additive protocol: `SegmentingTranscriptionService.transcribeWithSegments(audioURL:model:)
-> [TranscriptSegment]` (run VAD-off so times map to the raw WAV). Conformers today: whisper
`LocalTranscriptionService` (via `LibWhisper.getTimestampedSegments()`) and
`ParakeetTranscriptionService` (FluidAudio token timings → `ParakeetSegmentGrouper`). The
multi-source path consumes it via `TranscriptionServiceRegistry.segmentingService(for:)` — to make
a NEW provider Conversation-Mode-eligible, conform its service (see the **conversation-mode**
skill). Speaker **diarization** is still not supported (multi-source gets speakers ground-truth
per capture source instead). Note:

- **FluidAudio** (already a dependency, used for Parakeet) also provides **speaker diarization**.
- Cloud/streaming providers with native diarization: Deepgram, Soniox (both already integrated as providers).

## Checklist

- [ ] Model declared in `PredefinedModels`
- [ ] Service exists and is routed in `TranscriptionServiceRegistry.service(for:)` (or reuses Cloud)
- [ ] Streaming: provider in `createProvider`, `supportsStreaming` updated, fallback mapped
- [ ] API key storage + settings UI
- [ ] New files added to the Xcode target
