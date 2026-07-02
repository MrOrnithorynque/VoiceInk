# Conversation Mode (multi-source)

The opt-in multi-source capture + transcription subsystem, `Services/MultiSource/*`. Records the mic plus system/app audio as separate 16 kHz WAVs, transcribes each with the selected segment-capable model, and interleaves the segments by timestamp into one speaker-labeled transcript. Gating and start/stop live in `Whisper/VoiceInkEngine.swift` (see transcription-flow.md); the design spec for the diarization stage is `docs/plans/meeting-diarization-spec.md`.

## Assembly pipeline

`MultiSourceAssembler.assemble()` runs after recording stops: per-source transcription (via `SegmentingTranscriptionService`) → optional diarization stage (below) → `TranscriptMerger.merge` (per-segment clean, t0Offset shift, timestamp sort) → `composeFlatText` for the flat `Transcription.text`.

- `TranscriptMerger.swift` — pure merge/compose. A raw segment's `speaker` is normally empty and gets the source's role ("Me"/"Them"); a non-empty `speaker` — set by the diarization stage before merge — survives untouched, as does its `clusterId`.
- `MultiSourceTranscript.swift` — versioned persistence envelope + JSON encode/decode helpers. `currentSchemaVersion = 2` (v2 adds `TranscriptSegment.clusterId`; additive optional, decode-safe both directions).

## Speaker diarization (opt-in, on-device)

Gated on `ConversationDiarizationEnabled` (UserDefaults, default off). Toggle lives in `Views/Settings/AudioInputSettingsView.swift` inside the Conversation Mode section: enabling kicks off a cache-first model download and flips itself back off (with an alert) on failure. `VoiceInkEngine.tryStartMultiSource` re-attempts the same warm-up in a detached, non-fatal task while recording.

- `SpeakerDiarizationService.swift` — `actor` (singleton `shared`) wrapping FluidAudio's `DiarizerManager` (pyannote segmentation + WeSpeaker embeddings, CoreML). Two entry points with different network policies: `prepareModels()` MAY download (cache-first, in-flight-task deduped; settings toggle + record-start warm-up only), while `diarize(audioURL:)` is **cache-only** — it runs in the post-recording pipeline and throws `.modelsNotDownloaded` rather than touch the network. The speaker database is reset per file so cluster ids restart at "1" each recording.
- `MultiSourceAssembler.diarizeNonMicSources` — the stage itself. Only non-mic sources are diarized (the mic track is ground-truth "Me"); any per-source failure logs and keeps that source's role labels — diarization degrades, never fails the transcript.
- `SegmentSpeakerLabeler.swift` — pure cluster→segment assignment, no I/O or CoreML (unit-tested: `VoiceInkTests/SegmentSpeakerLabelerTests.swift`). `labelAll(_:)`: each segment gets the majority-time-overlap cluster (zero overlap → untouched); a source resolving to a single cluster keeps its role label ("Them", not "Speaker 1") though `clusterId` is still recorded; "Speaker N" names are minted in ONE global pass across all multi-cluster sources, ordered by first appearance on the shared timeline (start + t0Offset). `rename(segments:from:to:)`: pure label rewrite for user renames — callers must re-encode `segmentsJSON` AND recompose the flat `text` (see persistence-and-history.md).
- `Models/TranscriptSegment.swift` — `speaker` is the display label (ground-truth role by default, cluster label when diarized); `clusterId: String?` is the stable cluster key (`"<role>#<diarizer speakerId>"`, nil = ground-truth by source).

## Rendering

- `Views/ConversationTranscriptView.swift` — turn-grouped, speaker-colored transcript bubbles. Optional `onRenameSpeaker: ((String, String) -> Void)?` hook: when set (History detail), each turn header gets a "Rename speaker…" context menu + alert; read-only surfaces (`Views/TranscriptionResultView.swift`) pass nil.
