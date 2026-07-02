# Persistence & history

`Models/Transcription.swift` is the single SwiftData `@Model` for transcripts; the store is local-only (`cloudKitDatabase: .none` in `VoiceInk.swift`). History UI lives in `Views/History/*`.

## Transcription model

One flat `text` blob (+ optional `enhancedText`) and one `audioFileURL`, plus metadata (model names, durations, prompt/PowerMode names, status). Multi-source rows additionally carry two additive optional string columns — safe under SwiftData lightweight migration, nil for single-source/legacy rows:

- `segmentsJSON` — JSON `[TranscriptSegment]`, the merged speaker-labeled transcript.
- `audioSourcesJSON` — JSON `[AudioSourceRecord]`, per-source WAV + t0Offset + role.

Schema evolution of the JSON payloads is versioned inside the blobs, not in SwiftData: `MultiSourceTranscript.currentSchemaVersion` (currently 2 — v2 added `TranscriptSegment.clusterId` for diarization; additive optional, so v1 rows decode with it nil and v1 builds ignore the key; no SwiftData migration involved).

Computed helpers (extension): `hasSegments`, `isMultiSource`, `decodedSegments`/`decodedSources`, `allAudioFileURLs` (per-source WAVs when multi-source, else the single file — used by cleanup/deletion), and `speakerCount` for the History "N speakers" badge. `speakerCount` counts distinct segment speakers when segments exist (so diarized transcripts report every detected voice), dropping a source's role from the count when that track minted "Speaker N" clusters (role-labeled gap segments are spillover of an already-counted track); it falls back to counting source roles when segments are missing.

## History detail

`Views/History/TranscriptionDetailView.swift` renders `ConversationTranscriptView` for segmented rows (classic Original/Enhanced bubbles otherwise) and hosts speaker rename: `renameSpeaker(from:to:)` rewrites the label via `SegmentSpeakerLabeler.rename`, then persists **both** representations — `segmentsJSON` (drives the segment view + MD/VTT/SRT export) and the recomposed flat `text` via `TranscriptMerger.composeFlatText` (drives list previews, search, .txt/CSV export). Leaving `text` stale is the known trap (docs/plans/meeting-diarization-spec.md §8).
