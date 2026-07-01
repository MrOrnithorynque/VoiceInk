# Transcription providers

Batch and streaming services that turn a recorded WAV (or live audio) into text. The base contract is `Services/TranscriptionService.swift` (`transcribe(audioURL:model:) async throws -> String`, plain text, no timestamps); `Services/TranscriptionServiceRegistry.swift` routes a model to its service. Providers that can emit per-segment timestamps additionally conform to `SegmentingTranscriptionService` (`Services/SegmentingTranscriptionService.swift`), which is what qualifies a model for multi-source Conversation Mode.

## Batch services

- `LocalTranscriptionService.swift` — whisper.cpp models. Conforms to `SegmentingTranscriptionService` (whisper's native segments, VAD force-disabled on the segmenting path).
- `ParakeetTranscriptionService.swift` — Parakeet via FluidAudio. Conforms to `SegmentingTranscriptionService`:
  - `transcribeWithSegments(audioURL:model:)` — segmenting path for Conversation Mode. Deliberately skips the ≥20s VAD trimming that plain `transcribe(...)` does, so token times map linearly to the raw WAV; pads trailing silence (append-only, never shifts timestamps); groups FluidAudio token timings via `ParakeetSegmentGrouper`. Falls back to one whole-file segment when no token timings are returned. Emits segments with an empty `speaker` — `TranscriptMerger` stamps each source's role.
- `NativeAppleTranscriptionService.swift` — Apple Speech.
- `CloudTranscription/*` — cloud providers.

## Streaming

- `Services/StreamingTranscription/*` — live partials, opt-in per model (`TranscriptionServiceRegistry.supportsStreaming`).

## Segment helpers

- `Services/ParakeetSegmentGrouper.swift` — pure, synchronous grouping of Parakeet token timings into `TranscriptSegment`s (`Models/TranscriptSegment.swift`). Operates on a minimal `TimedToken` shape (mapped from `FluidAudio.TokenTiming` at the call seam) so it is unit-testable without a CoreML model (`VoiceInkTests/ParakeetSegmentGrouperTests.swift`). Rules: new segment when the inter-token gap exceeds `gapThreshold` (default 0.8s) or a segment would exceed `maxSegmentDuration` (default 15s); `normalizedText(_:)` handles SentencePiece `▁` markers whether or not FluidAudio pre-normalised them.
