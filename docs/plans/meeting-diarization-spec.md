# Meeting diarization — implementation spec

Branch: `feature/meeting-speaker-diarization`. Opt-in FluidAudio speaker diarization on
Conversation Mode's non-mic tracks: the system-audio ("Them") WAV is clustered into
`Speaker 1/2/3`, merged-transcript segments are relabeled, and a speaker can be renamed
after the fact. Fully on-device; the mic track is never diarized (it is ground-truth "Me").

## Verified foundation (FluidAudio @ 4de9aca, the pinned revision)

- `DiarizerManager(config:)` + `initialize(models:)`; `performCompleteDiarization(_ samples: [Float], sampleRate: 16000)` → `DiarizationResult.segments: [TimedSpeakerSegment]` (`speakerId: String` "1","2",…; `startTimeSeconds`/`endTimeSeconds: Float`; `embedding: [Float]` 256-d). Synchronous — run inside an actor, never on the main actor.
- `DiarizerModels.download()` is cache-first (HuggingFace `FluidInference/speaker-diarization-coreml` → `~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/`: `pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc`). No progress callback (same as AsrModels).
- Input conversion already exists: `WAVSampleReader.samples(from:) → [Float]` (used by Parakeet).

## Design decisions

1. **Insertion point**: `MultiSourceAssembler.assemble()`, after the per-source transcription
   loop and before `TranscriptMerger.merge`. Segments there are 0-based on the source WAV's
   own timeline — the same timeline the diarizer emits, so no t0Offset math.
2. **Only non-mic sources** (`!record.isMicrophone`) are diarized. Failure of the diarizer
   (models missing, audio invalid) degrades to today's role labels — never fails the transcript
   (matches the subsystem's per-source-degrade philosophy).
3. **Schema**: `TranscriptSegment` gains `var clusterId: String?` (additive optional —
   decode-safe both directions; precedent `AudioSourceRecord.kind`). `speaker` keeps being the
   display label; its doc comment is amended: ground-truth by source, OR an opt-in on-device
   diarization label when `clusterId != nil`. `MultiSourceTranscript.currentSchemaVersion` → 2.
4. **Labeling logic is pure and unit-tested** (`SegmentSpeakerLabeler`): assign each ASR
   segment the majority-overlap diarizer cluster; renumber clusters by first appearance
   globally across non-mic sources ("Speaker 1", "Speaker 2", …); a source whose diarization
   yields **one** cluster keeps its plain role label (no "Speaker 1" noise for a 1:1 call);
   zero-overlap segments keep the role and `clusterId = nil`.
   `clusterId` format: `"<role>#<diarizer speakerId>"` (roles are unique per invariant 5).
5. **Merge respects pre-set labels**: `TranscriptMerger.merge` currently clobbers
   `seg.speaker` with `record.role`; change to `seg.speaker.isEmpty ? record.role : seg.speaker`
   and carry `clusterId` through. Conformers still return `speaker: ""` so the mic path is
   byte-identical.
6. **Service**: `SpeakerDiarizationService` — an `actor` mirroring `ParakeetTranscriptionService`
   (lazy `ensureReady()` = `DiarizerModels.download()` + `DiarizerManager.initialize`, in-flight
   Task dedupe). API: `diarize(audioURL:) async throws -> [SpeakerRange]` where `SpeakerRange`
   is a plain `(speakerId, start, end)` value type.
7. **Gating**: new UserDefaults key `ConversationDiarizationEnabled` (default false), read at
   the stage in `assemble()`. Settings toggle in `AudioInputSettingsView` inside the existing
   `if twoSourceEnabled` block; enabling kicks off a background model download (cache-first).
8. **Rename**: context menu on the speaker header in `ConversationTranscriptView` (callback to
   the parent that owns the `Transcription`). Rename rewrites every segment whose `speaker`
   equals the old label, re-encodes `segmentsJSON`, **and recomposes `transcription.text` via
   `TranscriptMerger.composeFlatText`** — the stored flat text is a canonical cache used by
   .txt/CSV export, list previews, and search; leaving it stale is the known trap.
9. **`Transcription.speakerCount`** switches to counting distinct segment speakers when
   segments exist (today it counts source roles, which would undercount diarized transcripts).
10. **Out of scope (deliberate)**: cross-meeting voice enrollment (`SpeakerManager` supports it;
    later), the browser-extension name feed (separate roof, see research in this branch's PR),
    Sortformer/offline VBx variants, MultiTrackPlayer lane-color unification (lanes are
    per-source, transcript colors per-speaker — semantically distinct; documented divergence).

## Files

New: `Services/MultiSource/SpeakerDiarizationService.swift`,
`Services/MultiSource/SegmentSpeakerLabeler.swift`, `VoiceInkTests/SegmentSpeakerLabelerTests.swift`.

Modified: `Models/TranscriptSegment.swift`, `Models/Transcription.swift`,
`Services/MultiSource/TranscriptMerger.swift`, `Services/MultiSource/MultiSourceAssembler.swift`,
`Services/MultiSource/MultiSourceTranscript.swift`, `Views/ConversationTranscriptView.swift`,
`Views/History/TranscriptionDetailView.swift`, `Views/Settings/AudioInputSettingsView.swift`.

Docs to sync afterwards: `.claude/skills/conversation-mode/SKILL.md` + `CLAUDE.md`
("no ML diarization" claims become "opt-in diarization"), architecture docs, changelog entry.

## Test plan

Unit (Swift Testing, pure logic, no CoreML): majority-overlap assignment, first-appearance
renumbering, single-cluster → role passthrough, zero-overlap fallback, clusterId propagation
through merge, pre-set speaker survives merge, rename rewrites label + flat text recompose.
Run with `MACOSX_DEPLOYMENT_TARGET=14.4` (building-voiceink skill gotcha).

On-device (signed build only): tap audio is silent on ad-hoc builds; end-to-end diarization of
a real meeting requires a Developer-ID build per BUILDING.md.
