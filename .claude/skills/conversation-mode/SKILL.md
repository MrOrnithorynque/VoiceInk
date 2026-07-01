---
name: conversation-mode
description: Understand or modify VoiceInk's multi-source "Conversation Mode" — recording mic + system/app audio at once into one interleaved, timestamped, speaker-labeled transcript. Use for any work on Services/MultiSource/*, the multi-source branches of VoiceInkEngine/TranscriptionPipeline, the N-source settings UI, multi-track playback, or Markdown/VTT/SRT export. Covers the architecture, the load-bearing invariants, the correctness traps, and the persistence + deferred-migration decision.
---

# Conversation Mode (multi-source transcription)

Opt-in, **on-device / segment-capable model only**, macOS 14.4+. Captures N audio sources
simultaneously and produces one interleaved transcript (`[00:07] Me: … / [00:12] Them: …`).
Speaker identity is **ground-truth by capture source** — no ML diarization. **Model-agnostic:**
it runs the *selected* model once per source WAV and interleaves by timestamp, so any service that
conforms to `SegmentingTranscriptionService` qualifies — today **whisper `LocalTranscriptionService`
AND `ParakeetTranscriptionService`** (FluidAudio token timings → `ParakeetSegmentGrouper`). Gated on
`TwoSourceTranscriptionEnabled` (UserDefaults) + `serviceRegistry.segmentingService(for:) != nil`
for the effective model (NOT `.provider == .local`). The single-source dictation path is untouched.

## Data flow

```
AudioSourceConfig.active            (custom [AudioSourceConfig] in UserDefaults, else mic+system default)
   → CaptureSourceFactory.makeSources  (per-source degrade: skip failures, throw only if none build)
   → MultiSourceCaptureCoordinator([CaptureSource])   (one host-time anchor, start all, degrade)
        • MicCaptureSource        → CoreAudioRecorder (mic)      role kind "mic"
        • SystemAudioTapRecorder  → process tap (global/per-app) role kind "system"/"app"
   → each source writes a 16k/mono/Int16 WAV + reports first-buffer host time → t0Offset
   → VoiceInkEngine.handleMultiSourceStop → MultiSourceAssembler
        • SegmentingTranscriptionService.transcribeWithSegments(wav)  (VAD-off; whisper or Parakeet)
        • TranscriptMerger.merge  (clean per-segment → shift by t0Offset → flatMap → sort)
   → TranscriptionPipeline.runMultiSource  (persist segmentsJSON/audioSourcesJSON, paste flat text)
```

Key files: `Services/MultiSource/` (CaptureSource, MicCaptureSource, SystemAudioTapRecorder,
MultiSourceCaptureCoordinator, RecordingTimeline, TranscriptMerger, MultiSourceAssembler,
CaptureSourceFactory, AudioSourceConfig, MultiSourceTranscript, CoreAudioUtils,
AudioProcessEnumerator, MultiTrackPlayer), `Whisper/VoiceInkEngine.swift` +
`TranscriptionPipeline.swift`, `Models/{TranscriptSegment,AudioSourceRecord}.swift`,
`Views/{ConversationTranscriptView,MultiTrackPlayerView}.swift`,
`Views/Settings/AudioSourcesSettingsView.swift`, `Services/Export/*`. Capture-API details live in
the **core-audio-capture** skill; whisper timestamps in **add-transcription-provider**.

## Load-bearing invariants (do not break — the review caught bugs in each)

1. **Primary = the microphone, chosen by KIND, never by array index.** `handleMultiSourceStop`
   picks `records.first(where: \.isMicrophone) ?? records[0]` for the saved `audioFileURL`,
   duration, and the cloud-degrade transcription target; only **non-primary** WAVs are deleted.
   Selecting by index means a reordered tap at slot 0 deletes the user's own voice track.
2. **One pre-start host-time anchor.** `MultiSourceCaptureCoordinator.start` calls
   `timeline.anchorNow()` BEFORE starting any source; each source's `t0Offset` is measured from
   it. Never compare `mSampleTime` across devices — host time only (`RecordingTimeline`).
3. **Per-source degrade, not all-or-nothing.** `CaptureSourceFactory.makeSources` skips sources
   that can't be built (e.g. an app not currently playing) and throws only if none build; the
   coordinator drops sources that fail to *start* and proceeds if ≥1 started.
4. **Delete every WAV you handed out.** The coordinator tracks `startedURLs` and deletes them on
   `cancel()` / `discardStartedFiles()` — including zero-frame tap files that `makeSourceRecord`
   returns nil for. Cleanup is also multi-source-aware in `TranscriptionAutoCleanupService`
   (build the referenced set from `Transcription.allAudioFileURLs`, decoding `audioSourcesJSON`).
5. **Unique non-empty roles.** `TranscriptMerger.composeFlatText` groups by role string, so two
   "Them" sources would collapse. `AudioSourcesViewModel` enforces uniqueness (+ soft cap 4, no
   duplicate mic device incl. nil↔default, ≥1 mic).

## The 4 correctness traps (why the pipeline has a separate branch)

1. **Bracket filter strips `[mm:ss]`.** `TranscriptionOutputFilter` deletes anything in `[…]`.
   The multi-source path cleans **per-segment BEFORE composition** (in `MultiSourceAssembler`),
   so the composed `[mm:ss]`-prefixed text never hits that filter.
2. **VAD warps timestamps.** A model's internal VAD trims silence, making segment times
   non-linear and per-stream-different. Every `transcribeWithSegments` conformer MUST run
   VAD-off: whisper via `fullTranscribe(…, forceDisableVAD: true)`; Parakeet by skipping the
   ≥20s VAD-trim branch that `transcribe(…)` uses. Segment times then map to the raw WAV.
3. **Mute self-collision — avoided by construction.** The single-source `Recorder` mutes system
   output + pauses media on start. Multi-source drives `CoreAudioRecorder`/the tap **directly**
   (never `Recorder`), so it never mutes/pauses the app it's capturing.
4. **Enhancement mangling.** `runMultiSource` **skips AI enhancement** (off by default) so the
   LLM can't reflow the labeled `[mm:ss] Speaker:` layout.

## Persistence + migration

`Transcription` carries two **additive optional** fields: `segmentsJSON` (JSON
`[TranscriptSegment]`) and `audioSourcesJSON` (JSON `[AudioSourceRecord]`); legacy/single-source
rows have them nil and render the classic view. Wrapped conceptually by `MultiSourceTranscript`
(`schemaVersion`). **The `@Relationship` migration is intentionally DEFERRED** — nothing queries
across segments yet, and introducing the store's first relationship + custom `SchemaMigrationPlan`
adds real corruption/downgrade risk. The documented GO-plan (VersionedSchema + willMigrate
backfill + downgrade mitigation) is in `docs/plans/phase6-implementation-spec.md` §1; trigger it
only when a query-over-segments/segment-editing/CloudKit-sync feature actually lands.

## Extending it

- New source kind → add an `AudioSourceKind` case + a `CaptureSourceFactory` arm (guard
  `#available(macOS 14.4, *)` for taps); the coordinator/merger are already N-ready.
- Make another model eligible → conform its service to `SegmentingTranscriptionService`
  (`transcribeWithSegments`, VAD-off, return `speaker: ""` segments); the gate + assembler pick it
  up via `segmentingService(for:)` with no other change. See `ParakeetTranscriptionService` +
  `ParakeetSegmentGrouper` for the token-timings→segments pattern.
- Playback/export read the decoded blobs (`decodedSegments`/`decodedSources`) — no schema change.
- Anything touching the tap/aggregate/IOProc → read **core-audio-capture** first.
- On-device behavior (tap capture, TCC, playback sync) is **not headless-verifiable**; needs a
  signed build. See the spec test plans and BUILDING.md.
