I have everything I need. Here is the final Phase 6 spec.

# VoiceInk — Phase 6 Implementation Spec

**Scope:** Multi-source playback, structured export (Markdown / VTT / SRT), and a decision on the SwiftData relationship migration.
**Depends on:** Phases 0–5 (value types, timeline, capture coordinator, merge, persistence-as-JSON, N-source config). All paths below are under `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/`.

---

## 1. SwiftData relationship migration — **DECISION: DEFER**

### 1.1 Decision

**DEFER** the migration of multi-source data from the two JSON blobs (`Transcription.segmentsJSON`, `Transcription.audioSourcesJSON`) to first-class SwiftData `@Model` relationships (`TranscriptSegment` / `AudioSourceRecord` as related models). Ship Phase 6 on the existing JSON-blob shape.

### 1.2 Rationale

- **No feature in Phase 6 needs to query across segments or sources.** Playback and export both operate on a single already-loaded `Transcription`, decode its blobs once (`decodedSegments` / `decodedSources`), and work in memory. The only justification for a relationship is a `#Predicate` / `FetchDescriptor` over segments (e.g. "find every transcription where *Them* said X", cross-transcript speaker analytics). Nothing on the Phase 6 board does that.
- **The blobs are already forward-designed for the exact migration.** `MultiSourceTranscript` carries `currentSchemaVersion`, and `AudioSourceRecord` / `TranscriptSegment` are documented as "field-compatible with the future `@Model` so a Phase-6 relationship migration is a straight backfill." The cost of migrating later is unchanged by deferring — the envelope was built to make it a one-time `willMigrate` loop whenever we choose.
- **The migration is the single highest-risk change in the phase.** The app runs a *multi-store* container (`default.store` for `Transcription`, `dictionary.store` with **CloudKit** for the dictionary). Introducing a `SchemaMigrationPlan` on the transcript store means every existing user's DB migrates on the next launch; a bug there corrupts transcription history — the app's core asset. Phase 6's user value (hearing/exporting a conversation) is fully deliverable without touching the store schema.
- **Downgrade safety.** Adding related `@Model` types changes the store's model hash. A user who upgrades and then rolls back (Sparkle downgrade, TestFlight → stable) hits a store the older binary can't open. Staying on additive optional scalars keeps every Phase-6 build **backward- and forward-compatible** with the current store, exactly as Phases 1–5 were.

### 1.3 What would trigger GO later (revisit criteria)

Promote to relationships when **any** of these lands on the roadmap:

1. **Query-over-segments features:** global speaker search, "all turns by speaker X across history," per-speaker word counts, or a segments-backed analytics view.
2. **Segment editing:** in-place edit/re-attribute/split of an individual turn that must persist granularly (blob rewrite becomes contention-prone and loses per-segment identity/undo).
3. **Segment count so large** that decoding the whole JSON blob to render/search one transcription shows up in profiling (long meeting recordings, thousands of segments).
4. **CloudKit sync for transcripts.** If the transcript store ever moves to CloudKit like the dictionary store, relationships + a versioned plan become the sane representation (CKRecord-friendly), and we migrate then.

### 1.4 GO plan (documented now so it's ready when a trigger fires)

When triggered, this is the exact shape — kept here so the future implementer doesn't re-derive it.

**New file `Models/TranscriptionSchemas.swift`:**

- `enum TranscriptionSchemaV1: VersionedSchema` — `versionIdentifier = Schema.Version(1,0,0)`, `models = [Transcription.self]` (the current blob-carrying `Transcription`).
- `enum TranscriptionSchemaV2: VersionedSchema` — `versionIdentifier = Schema.Version(2,0,0)`, `models = [Transcription.self, TranscriptSegmentModel.self, AudioSourceModel.self]`.
  - `Transcription` in V2 gains `@Relationship(deleteRule: .cascade) var segments: [TranscriptSegmentModel]` and `var sources: [AudioSourceModel]`; the `segmentsJSON` / `audioSourcesJSON` columns are **retained** (not dropped) for one release as a rollback escape hatch, then removed in V3.
  - `@Model final class TranscriptSegmentModel` mirrors `TranscriptSegment` fields (`speaker/text/start/end`) + `var order: Int` for stable sort + inverse `var transcription: Transcription?`.
  - `@Model final class AudioSourceModel` mirrors `AudioSourceRecord` (`role/fileURLString/t0Offset/deviceName/processBundleID/kind`) + inverse.

**`enum TranscriptionMigrationPlan: SchemaMigrationPlan`:**

```
static var schemas = [TranscriptionSchemaV1.self, TranscriptionSchemaV2.self]
static var stages = [migrateV1toV2]
static let migrateV1toV2 = MigrationStage.custom(
    fromVersion: TranscriptionSchemaV1.self,
    toVersion:   TranscriptionSchemaV2.self,
    willMigrate: { context in
        // Backfill: for each Transcription, decode blobs → create child @Models.
        let all = try context.fetch(FetchDescriptor<Transcription>())
        for t in all {
            if let segs = MultiSourceTranscript.decodeSegments(t.segmentsJSON) {
                t.segments = segs.enumerated().map { i, s in
                    TranscriptSegmentModel(speaker: s.speaker, text: s.text,
                                           start: s.start, end: s.end, order: i)
                }
            }
            if let srcs = MultiSourceTranscript.decodeSources(t.audioSourcesJSON) {
                t.sources = srcs.map(AudioSourceModel.init(record:))
            }
        }
        try context.save()
    },
    didMigrate: nil
)
```

**Wire-up in `VoiceInk.swift`:** both `createPersistentContainer` and `createInMemoryContainer` change the transcript container init to pass `migrationPlan: TranscriptionMigrationPlan.self`, and the transcript `Schema` becomes `TranscriptionSchemaV2.self`. The dictionary config is untouched.

**Downgrade mitigation for GO:** keep `segmentsJSON`/`audioSourcesJSON` populated in V2 (dual-write in the pipeline) for exactly one shipped version so a rollback binary still renders multi-source history from the blobs; only in V3 (a later release, after the downgrade window closes) drop the JSON columns via a lightweight stage. Additionally, gate the V2 store behind a one-time `NSBackupExcludedItemKey`-independent **file copy** of `default.store` to `default.store.v1bak` in `willMigrate`, deletable after two successful launches — a manual safety net independent of SwiftData's own rollback.

> **Net for Phase 6: no schema change, no migration plan, no container edits.** All Phase 6 work reads the existing blobs.

---

## 2. Multi-track synchronized playback

### 2.1 Problem

Today `AudioPlayerView` plays a **single** file via `AVAudioPlayer` (`Views/AudioPlayerView.swift`). A multi-source `Transcription` has **N WAVs**, each with a per-source `t0Offset` placing its local 0-based timeline onto the shared recording clock. Phase 6 must play them as one synchronized timeline, with tap-to-seek and no cross-track drift, while keeping the existing single-source player unchanged for legacy/single rows.

### 2.2 Files to add

| File | Purpose |
|---|---|
| `Services/MultiSource/MultiTrackPlayer.swift` | `AVAudioEngine`-based synchronized N-track transport. **New.** |
| `Views/MultiTrackPlayerView.swift` | SwiftUI transport + per-speaker-tinted multi-lane waveform + tap-to-seek. **New.** |

### 2.3 Files to change

| File | Change |
|---|---|
| `Views/History/TranscriptionDetailView.swift` | In the `hasAudioFile` block, branch: if `transcription.isMultiSource`, render `MultiTrackPlayerView(sources: transcription.decodedSources!)` instead of `AudioPlayerView(url:)`. Single-source rows keep `AudioPlayerView`. |
| `Views/AudioPlayerView.swift` | Extract the reusable `WaveformView` seek/hover gesture into the file's existing struct (already reusable). Add `func seek(to:)` already exists. No behavioral change to single-source path. |

### 2.4 Transport design (`MultiTrackPlayer`)

**Engine graph.** One `AVAudioEngine`; per source one `AVAudioPlayerNode` → `engine.mainMixerNode`. Files opened as `AVAudioFile` (the WAVs are 16 kHz/mono/Int16; engine converts to the mixer format automatically). `@MainActor final class MultiTrackPlayer: ObservableObject`.

**Published state** (mirrors `AudioPlayerManager` so `MultiTrackPlayerView` is a straightforward adaptation): `isPlaying`, `currentTime` (shared-timeline seconds), `duration`, `perSourceWaveforms: [String: [Float]]` (keyed by `AudioSourceRecord.id`), `isLoadingWaveforms`.

**Timeline model.** `duration = max over sources of (t0Offset + fileDuration)`. `currentTime` is the shared-timeline position (t=0 = record start), *not* any single file's position. Each `AudioSourceRecord.t0Offset` is the delay before that source's first buffer.

**Sample-accurate scheduling (the sync mechanism).** Do **not** rely on wall-clock `play()` calls per node — that reintroduces the exact cross-device skew the timeline was built to remove. Instead schedule every node against **one shared `AVAudioTime` sample reference**:

```
let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
let startHostTime = mach_absolute_time() + smallLeadTicks   // ~50 ms lead
let startTime = AVAudioTime(hostTime: startHostTime)
for src in sources {
    let node = nodes[src.id]
    let offsetFrames = AVAudioFramePosition(src.t0Offset * sampleRate)
    // Position within THIS source's file for the requested shared-timeline `seekTime`
    let localSeek = seekTime - src.t0Offset
    if localSeek + srcFileDuration <= 0 { continue }          // source not yet audible / already ended
    let framePos = AVAudioFramePosition(max(0, localSeek) * srcFileSampleRate)
    let framesToPlay = file.length - framePos
    guard framesToPlay > 0 else { continue }
    node.scheduleSegment(file, startingFrame: framePos,
                         frameCount: AVAudioFrameCount(framesToPlay),
                         at: startTime.offset(seconds: max(0, src.t0Offset - seekTime), sampleRate))
    node.play(at: startTime)                                 // all nodes share startTime → sample-locked
}
engine.prepare(); try engine.start()
```

Key point: **all nodes are started against the same `startTime` host-time anchor**, and each source's own `t0Offset` is expressed as a *scheduling offset* (`at:`) rather than a separate `play()` timestamp. This is the same "one anchor before any stream starts" invariant `RecordingTimeline` enforces on the capture side, applied to playback.

**Progress reporting.** A `Timer` at 0.05 s reads the *reference* node's `lastRenderTime`/`playerTime` (pick the mic source as reference via `isMicrophone`, falling back to source[0]) and computes `currentTime = referenceLocalTime + referenceT0Offset`. Using render time (not wall clock) keeps the progress bar locked to actual audio output. On reaching `duration`: stop, reset `currentTime = 0`.

**Transport API:** `load(sources:)`, `play()`, `pause()`, `seek(to shared: TimeInterval)`, `cleanup()` (stop engine, detach nodes; called from `.onDisappear`, mirroring `AudioPlayerManager.cleanup()`).

### 2.5 Tap-to-seek

Reuse the existing `WaveformView` gesture contract: `onSeek: (Double) -> Void` receives a **shared-timeline** seconds value. `MultiTrackPlayerView` renders one waveform lane per source (stacked, tinted with `SpeakerPalette.color(index)` to match `ConversationTranscriptView`), each lane horizontally inset by `t0Offset / duration * width` so lanes line up visually on the shared clock. A single full-width hover/drag overlay spans all lanes and maps `x → shared seconds`; `seek(to:)` re-schedules all nodes from the new shared position (per the scheduling block above — sources whose `[t0Offset, t0Offset+fileDuration]` window doesn't contain the seek point are simply not scheduled until the timer crosses their `t0Offset`, at which point a lightweight re-arm on play handles late entry; simplest correct implementation: on every seek, `stop all → reschedule all from seekTime → play`).

Waveforms are generated with the existing `WaveformGenerator.generateWaveformSamples(from:)` (already cached by URL), one call per source in a `TaskGroup`.

### 2.6 Drift mitigation

1. **Single host-time anchor for all nodes** (above) — the primary guard. Nodes share one `AVAudioTime`, one clock, one mixer, so they cannot drift relative to each other once started.
2. **Reference-node render-time progress**, never wall clock, so the UI can't desync from audio.
3. **Seek = stop-all + reschedule-all** rather than per-node `currentTime =`, eliminating accumulated per-node offset error after scrubbing.
4. **Files stay in one engine/mixer** — no separate `AVAudioPlayer` instances (each of which has its own hardware clock and would drift). This is the concrete reason to move off `AVAudioPlayer` to `AVAudioEngine` for the multi-source case.
5. **Guard against a missing WAV:** if any `AudioSourceRecord.fileURL` no longer exists (cleanup ran), that lane is dropped and the transport plays the remaining sources; if none remain, fall back to the flat text with an inline "audio no longer available" note (parallels `TranscriptionDetailView.hasAudioFile`).

---

## 3. Export — Markdown / VTT / SRT + `MultiSourceExportService`

### 3.1 Files to add

| File | Purpose |
|---|---|
| `Services/Export/TranscriptExportFormat.swift` | `enum TranscriptExportFormat { case markdown, vtt, srt, txt }` + UTType/extension/display-name. **New.** |
| `Services/Export/MarkdownTranscriptSerializer.swift` | Segments → Markdown. **New.** |
| `Services/Export/VTTTranscriptSerializer.swift` | Segments → WebVTT. **New.** |
| `Services/Export/SRTTranscriptSerializer.swift` | Segments → SubRip. **New.** |
| `Services/Export/MultiSourceExportService.swift` | Orchestrator: picks serializer, builds filename, runs `NSSavePanel`, writes. **New.** |

All serializers are **pure** (`static func serialize(_ transcription: Transcription) -> String`), no I/O, unit-testable — same discipline as `TranscriptMerger`.

### 3.2 Shared timecode helpers (in `TranscriptExportFormat.swift`)

```
// mm:ss.mmm not needed for MD; VTT/SRT need HH:MM:SS with fractional seconds.
static func vttTimestamp(_ t: TimeInterval) -> String   // "HH:MM:SS.mmm" (dot)
static func srtTimestamp(_ t: TimeInterval) -> String    // "HH:MM:SS,mmm" (comma)
```

Both compute `h = Int(t)/3600`, `m = (Int(t)%3600)/60`, `s = Int(t)%60`, `ms = Int((t - floor(t))*1000)`, zero-padded (`%02d`/`%03d`).

### 3.3 Markdown format (`MarkdownTranscriptSerializer`)

Multi-source (has segments): one turn per grouped speaker block, matching `TranscriptMerger`/`ConversationTranscriptView` grouping (consecutive same-speaker segments merged).

```
# Conversation Transcript

**Date:** July 1, 2026 at 1:46 PM
**Duration:** 4m 12s
**Speakers:** Me, Them
**Model:** whisper-large-v3

---

**[00:00] Me:** Hey, thanks for hopping on.

**[00:04] Them:** No problem at all.

**[00:11] Me:** So about the roadmap…
```

- Header lines are omitted when the underlying field is nil (no "Model:" line if `transcriptionModelName == nil`).
- `[mm:ss]` uses `TranscriptSegment.timecode` for the first segment of each turn.
- **Single-source fallback** (no segments): render the classic doc — `# Transcription`, Date, then `text`, and if `enhancedText != nil` a `## Enhanced` section. This subsumes and replaces the ad-hoc `formatAsMarkdown` currently inside `AnimatedSaveButton`.

### 3.4 WebVTT format (`VTTTranscriptSerializer`)

One cue per **segment** (not per grouped turn — subtitle formats want short cues). Speaker as a VTT voice tag `<v Role>`.

```
WEBVTT

1
00:00:00.000 --> 00:00:03.480
<v Me>Hey, thanks for hopping on.

2
00:00:04.120 --> 00:00:06.900
<v Them>No problem at all.
```

- Blank line after `WEBVTT`, blank line between cues (required by spec).
- Cue index is optional in VTT but included for parity with SRT.
- Escape `-->`, `<`, `&` in text per VTT rules (`&` → `&amp;`, `<` → `&lt;`; `>` left as-is except in `-->`).
- **Single-source fallback:** one cue `00:00:00.000 --> {duration}` with the full `text` (no voice tag).

### 3.5 SubRip format (`SRTTranscriptSerializer`)

One cue per segment. No speaker tag syntax in SRT, so prefix the line with `Role: `.

```
1
00:00:00,000 --> 00:00:03,480
Me: Hey, thanks for hopping on.

2
00:00:04,120 --> 00:00:06,900
Them: No problem at all.
```

- Comma decimal separator (SRT convention), sequential 1-based index, blank line between cues, trailing newline at EOF.
- **Single-source fallback:** single cue `00:00:00,000 --> {duration}` with `text`.

**Zero-duration guard (VTT+SRT):** if a segment has `end <= start` (possible for a very short whisper segment), pad `end = start + 0.5` so players don't reject a zero-length cue.

### 3.6 `MultiSourceExportService`

```
@MainActor
final class MultiSourceExportService {
    static func serialize(_ t: Transcription, as format: TranscriptExportFormat) -> String
    // presents NSSavePanel(allowedContentTypes:[format.contentType]),
    // default name = suggestedFileName(t) + "." + format.fileExtension, then writes UTF-8.
    func export(_ t: Transcription, as format: TranscriptExportFormat)
    // bulk: writes multiple files or a concatenated doc — used from History multi-select.
    func exportBatch(_ ts: [Transcription], as format: TranscriptExportFormat)
}
```

- `serialize` dispatches to the four serializers.
- `suggestedFileName` reuses the word-extraction logic currently in `AnimatedSaveButton.generateFileName()` — **lift that helper into a free function** `TranscriptFilename.suggested(from:)` in the export module and have `AnimatedSaveButton` call it too (removes duplication).
- Save path mirrors `AnimatedSaveButton.saveFile` (`NSSavePanel`, `runModal()`, `write(to:atomically:encoding:.utf8)`), so behavior/permissions are identical to today's TXT/MD save.

### 3.7 Save-UI integration points

1. **`Views/Common/AnimatedSaveButton.swift`** — this is the per-transcription save menu already wired into `TranscriptionResultView` (lines 46/54) and available in History detail. Extend its `Menu`:
   - Keep `Save as TXT`, `Save as MD` (route MD through `MarkdownTranscriptSerializer` now, so multi-source rows get the conversation format instead of raw text).
   - Add, **conditionally shown only when the bound transcription `isMultiSource`**, `Save as VTT` and `Save as SRT`.
   - Requires giving `AnimatedSaveButton` access to the `Transcription` (today it only takes `textToSave: String`). Change its API to `init(transcription: Transcription)` (or add an optional `transcription` alongside `textToSave` for the non-transcription call sites) and route all formats through `MultiSourceExportService.serialize`. Callers in `TranscriptionResultView` pass the live `Transcription`.

2. **`Views/History/TranscriptionHistoryView.swift`** — already owns `VoiceInkCSVExportService` (line 21) and multi-select. Add an **"Export…" submenu** to the existing bulk/context menu offering Markdown / VTT / SRT via `MultiSourceExportService.exportBatch`, sitting next to the current CSV export. CSV export stays as-is (it's the tabular/analytics export; the new serializers are the human-readable/subtitle exports).

3. **`Views/AudioPlayerView.swift` / `MultiTrackPlayerView`** — no export UI added here; export stays in the save button + history menu to avoid a third surface.

---

## 4. Build & test plan

### 4.1 Build

- Add all new files to the `VoiceInk` target in `VoiceInk.xcodeproj`. New folders `Services/Export/` and files under `Services/MultiSource/` and `Views/`.
- Per project convention (`building-voiceink`): `make build` for a normal debug build; `make local` for the `LOCAL_BUILD` variant (dictionary CloudKit disabled) — verify **both** compile since Phase 6 touches no `#if LOCAL_BUILD` code but History/models are shared.
- No new entitlements, no Info.plist changes, no new frameworks (`AVFoundation` and `SwiftData` already linked). Confirm `AVAudioEngine` usage doesn't require any capability beyond existing mic entitlement (playback needs none).

### 4.2 Unit tests (pure, no device)

Add `VoiceInkTests` cases (mirroring the existing `TranscriptMerger`-style pure tests):

- **`MarkdownTranscriptSerializerTests`**: multi-source grouping (consecutive same-speaker merge), nil-header omission, single-source + enhanced fallback.
- **`VTTTranscriptSerializerTests`**: header/blank-line structure, `<v Role>` tag, timestamp `HH:MM:SS.mmm`, `&`/`<` escaping, zero-duration padding, single-source one-cue fallback.
- **`SRTTranscriptSerializerTests`**: comma separator, 1-based sequential index, `Role:` prefix, blank-line separation, zero-duration padding.
- **`TranscriptTimecodeTests`**: `vttTimestamp`/`srtTimestamp` at 0, sub-second, >1h boundaries.
- **`TranscriptFilenameTests`**: word extraction / sanitization parity with prior `AnimatedSaveButton` behavior.
- **Migration `willMigrate` (GO plan only — not built now):** N/A this phase; add when a trigger fires.

### 4.3 Manual / integration tests (device)

Record a two-source conversation (mic + system) via existing multi-source flow, then in History detail:

1. **Playback sync:** press play — both tracks audible, progress bar tracks the mic; a source with nonzero `t0Offset` starts audibly later, not clipped.
2. **Tap-to-seek:** click at ~50% — all tracks jump to the correct shared position and stay locked; scrub back and forth 5× and confirm no cumulative drift (A/B against the live conversation timing).
3. **Missing-file degradation:** delete one source WAV from disk, reopen — remaining source plays, no crash.
4. **Single-source regression:** open a legacy/single-source transcription — the classic `AudioPlayerView` renders and behaves exactly as before (no `MultiTrackPlayerView`).
5. **Export round-trip:** export the conversation as VTT and SRT; load each into a subtitle-aware player (e.g. VLC / QuickTime with the matching audio) and confirm cues sync to speech; open the Markdown in a viewer and confirm speaker grouping + timestamps match `ConversationTranscriptView`.
6. **Bulk export from History:** multi-select 3 rows → Export → SRT; confirm filenames and contents.
7. **Save-button conditionality:** confirm VTT/SRT entries appear only for multi-source rows and are hidden for single-source rows.

### 4.4 Security / privacy gate

Run the `security-checklist` before shipping (Phase 6 handles audio + transcript data and writes files chosen by the user). Confirm: exports contain only user-owned transcript/audio (no keys, no system messages unless already user-visible), all writes go through user-selected `NSSavePanel` URLs (no silent writes), and no new network egress.

### 4.5 Docs

Per `documentation-swift`: every new Swift file gets a header comment and every public decl a doc comment; then delegate the architecture-doc update to the `docs-updater` sub-agent. Add a `docs/changelog/` entry (multi-track playback + MD/VTT/SRT export) per the `changelog` skill.

---

**Relevant existing files (integration anchors):**
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Models/Transcription.swift` — `decodedSegments`/`decodedSources`/`isMultiSource` accessors used by playback + export.
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Views/AudioPlayerView.swift` — reusable `WaveformView` + `AudioPlayerManager` (single-source path, unchanged).
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Views/History/TranscriptionDetailView.swift` — playback branch point (`hasAudioFile`).
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Views/ConversationTranscriptView.swift` + `SpeakerPalette.swift` — turn grouping + colors that Markdown export and the multi-lane waveform must match.
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Services/MultiSource/TranscriptMerger.swift` — grouping logic the Markdown serializer parallels.
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/Views/Common/AnimatedSaveButton.swift` + `Services/VoiceInkCSVExportService.swift` — the two save-UI integration surfaces.
- `/Users/louisobenicherousse/Projects/VoiceInk/VoiceInk/VoiceInk.swift` — `ModelContainer` setup (untouched under the DEFER decision).