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

## Caption bridge (meeting-name feed, M1)

Opt-in feed of real participant names scraped from the meeting page's captions (Google Meet / Teams) by a companion browser extension; spec is `docs/plans/meeting-name-feed-spec.md`. M1 is plumbing only: events are collected during a recording, counted, and dropped at stop — the M2 name resolver that maps them onto diarization clusters does not exist yet.

- `Services/MultiSource/CaptionBridgeServer.swift` — `actor` (singleton `shared`) running a loopback-only (`127.0.0.1`) NWListener WebSocket server; probes ports 47810–47819 (tests pin a port via `init(port:)`). JSON text frames: extension sends `hello` (must carry the pairing token; bad token → `error` frame, closed only after the frame is on the wire), `caption` (`name`/`text`/`tsMs`/`turnId` — `tsMs` is browser `Date.now()`, same wall clock as the app's `Date()`), and `bye`; app sends `hello_ack` and `session` state broadcasts. Caption frames are buffered **in memory only**, keyed by `turnId` (replace-on-update), and only while a session is active — no sidecar files, the buffer dies with the session. `beginSession()`/`endSession()` bracket a recording; `endSession()` never blocks on the network and returns whatever arrived, sorted by `tsMs`. `pairingToken()` is a UUID generated once into UserDefaults (`CaptionBridgeToken`) — a local-authorization secret, not a cloud credential. Origin allowlisting is deferred to M3 (Network.framework's WS server API doesn't expose upgrade headers); the token is the gate. Integration-tested: `VoiceInkTests/CaptionBridgeServerTests.swift`.
- Gating: `CaptionBridgeEnabled` (UserDefaults, default off). The settings toggle ("Name speakers from your meeting page (beta)", `Views/Settings/AudioInputSettingsView.swift`) is nested under the diarization toggle (names need clusters), mirrors its revert-on-setup-failure pattern, and shows the pairing token with a copy button.
- Engine bracket: `VoiceInkEngine.tryStartMultiSource` opens the session in a non-blocking task (listener failure just means no captions — the transcript keeps "Speaker N" labels); `handleMultiSourceStop` closes it via `endCaptionSession()` on every exit path (cancel, no-audio, assemble, single-source fallback).

## Rendering

- `Views/ConversationTranscriptView.swift` — turn-grouped, speaker-colored transcript bubbles. Optional `onRenameSpeaker: ((String, String) -> Void)?` hook: when set (History detail), each turn header gets a "Rename speaker…" context menu + alert; read-only surfaces (`Views/TranscriptionResultView.swift`) pass nil.
