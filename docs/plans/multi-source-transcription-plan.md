# VoiceInk Multi-Source Timestamped Transcription — Final Implementation Plan

*Lead architect's final plan. Synthesizes the MVP and UX proposals, resolves every valid critique point (filter/timestamp corruption, VAD time-base warp, enhancement mangling, mute/pause self-collision, RT-safety, PowerMode gating, host-time fallback, self-exclusion), and stays grounded in real file paths. The dedicated architecture/extensibility lens is appended as the **Architecture & Extensibility Addendum** at the end of this document — read it alongside the "Files to Add / Modify" and "Data Model" sections, as it refines several of their decisions (a `CaptureSource` protocol, an N-source coordinator, a `SegmentingTranscriptionService` seam, a versioned persistence envelope, and a config factory).*

---

## Summary

VoiceInk will gain the ability to record the microphone ("Me") and system/other-app audio ("Them") simultaneously and produce a single interleaved, timestamped, speaker-labeled transcript (`[00:07] Me: …` / `[00:12] Them: …`). Speaker identity is ground-truth by capture source — no ML diarization — so there is zero diarization-error risk. The feature ships behind an off-by-default, local-model-only flag as a thin opt-in wrapper that never rewrites the load-bearing single-source path. Two correctness traps the naive design would hit — the existing bracket-stripping output filter destroying `[mm:ss]` prefixes, and whisper's VAD warping intra-stream timestamps into a non-linear time base — are resolved before any user sees output.

---

## Scope & Phased Roadmap

Each phase is independently shippable. The feature stays gated off-by-default until Phase 4. Two empirical gates block progress: the **VAD/timestamp golden-WAV spike** gates Phase 1→2, and the **filter/enhancement correctness fix** gates Phase 4 shipping.

| Phase | Deliverable | User-visible? | Est |
|---|---|---|---|
| **0 — Foundations** | `Info.plist` `NSAudioCaptureUsageDescription`; entitlements verified; `@available(macOS 14.4, *)` strategy confirmed against all pbxproj configs; new `PermissionsView` card; `BUILDING.md` signing note; **blocking migration spike** (forward + downgrade round-trip against a populated `default.store`). | Permission card | 1d |
| **1 — Timestamps (single-source too)** | `getTimestampedSegments()` in LibWhisper (unit-corrected), `transcribeWithSegments` (VAD explicitly disabled on this path — see gate below), `TranscriptSegment`/`AudioSourceRecord` types, `RecordingTimeline` (atomic, RT-safe), additive host-time capture in `CoreAudioRecorder`. **Blocking golden-WAV spike resolves the VAD time-base question before Phase 2.** | No (plumbing) | 2d |
| **2 — System-audio capture** | `SystemAudioTapRecorder` (tap→aggregate→IOProc, RT-safe `ExtAudioFileWrite`, **self-exclusion implemented**), shared `PCMConverter`, output-device-change watch with rebuild. Dev-testable on a signed build. | No (dev-testable) | 2.5d |
| **3 — Coordinator + merge + persist + conflict suppression** | `DualSourceRecorder` (graceful mic-only degradation; **suppresses mute/pause when active**), `TranscriptMerger`, `segmentsJSON`/`audioSourcesJSON`, cleanup helper `allAudioFileURLs(for:)`, cancel-both-WAVs. | No (internal) | 2d |
| **4 — Wire-up + MVP ship** | Engine + pipeline **multi-source branch** (bypasses bracket-stripping filter; conversation-safe enhancement policy) behind `TwoSourceTranscriptionEnabled` && **effective** local model (PowerMode-resolved); settings toggle; per-source recorder meters with live "no audio" detection; `ConversationTranscriptView` in result popup + History detail; list badge + metadata sources. **First shippable MVP: mic + system, "Me"/"Them", timestamped, local-only.** | **Yes — full MVP** | 3d |
| **5 — Arbitrary-N + per-app (post-MVP)** | `.audioSources` ViewType + `AudioSourcesSettingsView` + `SystemAudioCaptureManager` (process enumeration, per-app tap), second-mic support (with documented no-drift-compensation caveat), per-source name/color, `AudioSourceConfig` persistence. Merge/coordinator already N-ready. | Yes | ~3.5d |
| **6 — Relationship migration + rich UX (later)** | `VersionedSchema`+`SchemaMigrationPlan`; promote JSON blobs to `@Model` relationships (backfill); multi-track playback + tap-to-seek; Markdown/VTT/SRT export; optional ML-diarization tier for multi-remote-speaker-in-one-stream. | Yes | ~4d+ |

**MVP (Phases 0–4): ~10.5 days.** The single-source path is untouched throughout.

**Cut from each phase:**
- **Phase 1 cuts:** word/token-level timestamps (segment granularity only); keeping VAD on the multi-source path (disabled for time-base correctness).
- **Phase 2 cuts:** per-app tap selection; multi-track capture beyond mic+system.
- **Phase 3 cuts:** live merged partial transcript (merge is post-stop; live partial stays mic-only single-source).
- **Phase 4 cuts (the honest MVP boundary):** arbitrary-N, per-app selection, multiple mics, configurable-N — **all deferred to Phase 5** (see Open Questions — this is the trade-off the user must confirm). Also cut: multi-track playback, PowerMode per-source config, two-source import/retranscribe, dedicated segment export, streaming multi-source.
- **Phase 5 cuts:** `@Relationship`/`VersionedSchema` migration; querying over speakers ("everything Them said").

---

## Architecture

```
                                    ┌─────────────────────────────────────────────┐
                                    │              VoiceInkEngine                  │
                                    │  gate = @AppStorage("TwoSourceEnabled")      │
                                    │      && EFFECTIVE model == .local            │
                                    │      (re-checked AFTER PowerMode resolves)   │
                                    └───────────────┬─────────────────────────┬────┘
                                                    │ off / not local         │ on + local
                              ┌─────────────────────▼──────┐    ┌─────────────▼───────────────────┐
                              │   EXISTING single-source    │    │      DualSourceRecorder          │
                              │   Recorder → CoreAudioRec.  │    │      (@MainActor coordinator)    │
                              │   (UNCHANGED load-bearing)  │    │  owns shared RecordingTimeline   │
                              │   mute/pause fire as today  │    │  SUPPRESSES mute + pause          │
                              └─────────────────────────────┘    └──┬───────────────────────────┬───┘
                                                                    │                           │
                                              ┌─────────────────────▼───────┐   ┌───────────────▼──────────────────┐
                                              │  Recorder (mic, REUSED)      │   │  SystemAudioTapRecorder (NEW)     │
                                              │  CoreAudioRecorder AUHAL     │   │  CATapDescription(excludeProcesses│
                                              │  + RT-safe host-time (atomic)│   │    :[ownProcessObjectID]) →       │
                                              │  role = "Me"                 │   │  CreateProcessTap → private       │
                                              └──────────────┬───────────────┘   │  Aggregate(main=defaultOutput) →  │
                                                             │                   │  IOProc (ExtAudioFileWrite, RT)   │
                                          mic WAV (16k/mono) │                   │  role = "Them"                    │
                                            + sourceT0Offset │                   └───────────────┬──────────────────┘
                                                             │            sys WAV │ + sourceT0Offset
                                                             │   ┌──────────────────────┐        │
                                                             └──►│  shared PCMConverter  │◄───────┘
                                                                 │  (downmix+resample,   │
                                                                 │   pre-alloc buffers)  │
                                                                 └──────────────────────┘
                                                             │                           │
                              ┌──────────────────────────────▼───────────────────────────▼──────────────────┐
                              │   Per-source transcription (LocalTranscriptionService, VAD-OFF path)          │
                              │   transcribeWithSegments(mic.wav) → [(t0,t1,text)]   SEQUENTIAL (whisper      │
                              │   transcribeWithSegments(sys.wav) → [(t0,t1,text)]   actor serializes → 2×    │
                              │   segment times are in RAW-WAV time base (VAD disabled)  wall-clock latency)  │
                              └──────────────────────────────┬──────────────────────────────────────────────┘
                                                             │  each segment shifted by its source's t0Offset
                                              ┌──────────────▼──────────────┐
                                              │   TranscriptMerger (N-source)│
                                              │   per-segment filter/format/ │  → [TranscriptSegment]{speaker,text,start,end}
                                              │   word-replace, then         │      (segment.text already cleaned)
                                              │   flatMap + sort by start    │
                                              └──────────────┬──────────────┘
                                                             │
                              ┌──────────────────────────────▼──────────────────────────────────────────────┐
                              │  TranscriptionPipeline — MULTI-SOURCE BRANCH (does NOT reuse bracket filter)  │
                              │  • segments already filtered per-segment (no [mm:ss]-destroying pass)         │
                              │  • enhancement: conversation-aware OR off-by-default (see policy)             │
                              │  • compose flat text FROM (possibly enhanced) segments → save → paste         │
                              └──────────────────────────────┬──────────────────────────────────────────────┘
                                                             │
                              ┌──────────────────────────────▼──────────────────────────────────────────────┐
                              │  Transcription (SwiftData)                                                    │
                              │   text = flat labeled transcript (universal payload: search/copy/paste/CSV)   │
                              │   audioFileURL = mic WAV (primary; all 26 single-file call sites unchanged)    │
                              │   segmentsJSON = [TranscriptSegment]   audioSourcesJSON = [AudioSourceRecord]  │
                              └──────────────────────────────┬──────────────────────────────────────────────┘
                                                             │
                        ┌────────────────────────────────────▼─────────────────────────────────────────┐
                        │  UI: ConversationTranscriptView (result popup + History detail)                │
                        │  falls back to classic Original/Enhanced bubbles when segmentsJSON is nil       │
                        │  (imported / retranscribed / legacy single-source rows all hit fallback)         │
                        └────────────────────────────────────────────────────────────────────────────────┘
```

**Narrative.**

- **AudioSource abstraction.** Each capture stream is modeled by an `AudioSourceRecord` (`role`, `fileURL`, `t0Offset`, optional `deviceName`/`processBundleID`). `role` is a free-string ("Me"/"Them" in v1) and the reserved fields make the model N-ready without re-migration. The mic and system tap are two independent capture graphs unified *only* by `mHostTime` — either can fail independently.

- **CaptureCoordinator (`DualSourceRecorder`).** A `@MainActor` coordinator owns the reused mic `Recorder`, a new `SystemAudioTapRecorder`, and the shared `RecordingTimeline`. It establishes a single `mach_absolute_time()` anchor *before* starting either stream, starts both, and on stop returns two WAVs plus their `sourceT0Offset`s. If the tap fails to create/start, it degrades to mic-only (one source, identical to today's output). It is the single place that suppresses the mute/pause self-collision (below).

- **Per-source transcription.** Each WAV runs an independent local-whisper pass via `transcribeWithSegments`, on a VAD-disabled path so segment times map to the raw WAV timeline. Because `WhisperContext` is an `actor`, the two passes serialize — this is 2× wall-clock latency, surfaced honestly in progress UI.

- **Merge/interleave.** `TranscriptMerger` shifts each source's segments by its `t0Offset`, `flatMap`s across sources, and sorts by adjusted start — O(n log n), pure, unit-testable, N-source-capable. Per-segment text is filtered/formatted/word-replaced *before* composition so the merged flat text never passes through the bracket-stripping filter.

---

## macOS Capture Strategy

**Mic — unchanged.** Existing `CoreAudioRecorder` AUHAL path (`kAudioUnitSubType_HALOutput`, input element 1), bound to `AudioDeviceManager.getCurrentDevice()`. Role = "Me". The *only* addition is RT-safe host-time capture (below).

**System audio — Core Audio process taps, NOT ScreenCaptureKit.** SCK triggers recurring "Screen Recording" re-authorization on macOS 15+ even for audio-only — wrong for a background utility. Process taps are a one-time audio-capture TCC grant (Apple's AudioCap sample). Verified sequence:

1. Resolve **own** process object via `kAudioHardwarePropertyTranslatePIDToProcessObject` + `getpid()`; verify it returns a valid object before recording.
2. `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObjectID])` — all system output **minus VoiceInk itself** (self-exclusion is load-bearing; §critique #3). `.uuid = UUID()`, `.muteBehavior = .unmuted`, `.isPrivate = true`.
3. `AudioHardwareCreateProcessTap(desc, &tapID)`; read native format via `kAudioTapPropertyFormat`.
4. Resolve default output device UID (`kAudioHardwarePropertyDefaultSystemOutputDevice` → `kAudioDevicePropertyDeviceUID`) as the aggregate's **clock anchor**.
5. `AudioHardwareCreateAggregateDevice` with `MainSubDeviceKey`=outputUID, `IsPrivateKey`=true, `TapAutoStartKey`=true, `TapListKey`=[{`SubTapUIDKey`: uuid, `SubTapDriftCompensationKey`: true}].
6. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`. **In the block: RT-safe only** — capture host time into a pre-allocated atomic, downmix+resample via shared `PCMConverter` into pre-allocated buffers, write with `ExtAudioFileWrite` (mirroring `CoreAudioRecorder`, *not* `AVAudioFile.write`, which allocates on the RT thread — §critique #9).
7. Teardown (strict): `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

Do **not** use `AVAudioEngine` for the tap (silently reads default input instead — AudioCap-confirmed). Do **not** guard-free-compile: all `MultiSource` capture code carries `@available(macOS 14.4, *)` (`AudioHardwareCreateProcessTap` is @14.2, but at least one pbxproj config targets 14.0 — §critique F).

**Per-app audio — deferred (Phase 5).** v1 uses only the global "everything minus self" tap. Per-app uses `CATapDescription(stereoMixdownOfProcesses:)` after `kAudioHardwarePropertyProcessObjectList` enumeration + `kAudioProcessPropertyBundleID` matching; `AudioSourceRecord.processBundleID` reserved for it.

**Second mic — deferred (Phase 5), with a hard caveat.** Two independent AUHAL mic instances have unrelated hardware clocks with **no drift compensation** (unlike mic+tap, where the tap aggregate provides `SubTapDriftCompensation` and mic+tap share the system clock). Two-mic sessions will drift over long recordings; Phase 5 scoping must include this.

**Time alignment.** Two capture graphs unified purely via `mHostTime`. **Never compare raw `mSampleTime`** across independent devices — `RecordingTimeline` is the sole guardrail. Resolved gaps from critiques:
- **Explicit pre-start anchor (§critique #2b):** `DualSourceRecorder.start()` takes one `mach_absolute_time()` snapshot *before* starting either stream; each source's `t0Offset` is computed relative to that snapshot, not "first buffer wins."
- **Host-time fallback (§critique #2a):** in each callback, if `kAudioTimeStampHostTimeValid` is not set on `inTimeStamp.mHostTime` (driver-dependent for some aggregate/USB devices), fall back to `mach_absolute_time()` captured at the top of the callback, and log which path was used.
- **Non-zero-offset assertion:** after stop, assert both sources produced a plausibly-small non-nil `t0Offset`; a `0` offset from missing host time surfaces a warning rather than silently mis-interleaving.
- **RT-safety of the anchor (§critique F):** `RecordingTimeline`'s anchor is an OS-atomic (e.g. `OSAllocatedUnfairLock`-free atomic store or `Atomic<UInt64>`), written lock-free/allocation-free from both audio threads, read off-thread. No `weak var`/Swift-closure touch on the RT thread; the mic AUHAL C-function-pointer callback writes host time into the pre-allocated atomic only.
- Intra-tap-aggregate drift is auto-handled by `SubTapDriftCompensationKey`; mic+tap share the system clock so host time doesn't drift for dictation-length sessions.

**Mute / pause self-collision — RESOLVED (§critique A1, the critical one).** `Recorder.startRecording` (Recorder.swift:141-145) unconditionally calls `playbackController.pauseMedia()` and `mediaController.muteSystemAudio()`. `MediaController.muteSystemAudio()` (MediaController.swift:23-48) sets `kAudioDevicePropertyMute = 1` on the **default output device** — the exact device the tap uses as its aggregate clock anchor — and `pauseMedia()` **pauses the very app the user wants to capture** (YouTube/Zoom/podcast). Left unfixed, the feature silences or self-defeats its own primary use case. **Fix:** when the two-source flag is active, `DualSourceRecorder` suppresses **both** `muteSystemAudio()` and `pauseMedia()` for the session duration (restoring the user's setting semantics afterward), regardless of the user's `isSystemMuteEnabled`/`isPauseMediaEnabled` defaults. The settings toggle must state: "System audio capture keeps other apps playing and audible while recording." QA gate: record with both defaults ON, confirm the "Them" track is non-silent and the media app keeps playing.

**Device-change robustness (§critique #5).** The aggregate's clock anchor is the default output device; switching output mid-record (AirPods connect, HDMI unplug — routine) makes the IOProc stop delivering buffers or deliver silence, **not merely "truncate."** v1 watches `kAudioHardwarePropertyDefaultSystemOutputDevice` and **tears down + rebuilds** the aggregate/tap around the new output device. If rebuild proves too costly to land in v1, the fallback requirement is that the level-based "no audio detected" recorder hint reliably fires on this specific case so the user sees it live and can restart — and empirical confirmation of the actual IOProc behavior on device change is a blocking QA item before shipping.

**Permissions / Info.plist / entitlements.**
- **Info.plist:** add `NSAudioCaptureUsageDescription` (distinct TCC bucket from `NSMicrophoneUsageDescription`). Single shared Info.plist covers both `make build` and `make local`.
- **Entitlements:** `com.apple.security.device.audio-input` already present (lines 19-20); app is unsandboxed → **no new entitlement key**. Keep `.entitlements` + `.local.entitlements` in sync.
- **Permission UI:** just-in-time (opt-in, off by default), no new onboarding step. New `PermissionsView` card for a permanent re-grant surface.
- **Silent-failure detection (§critique #2, #6, B2):** an improperly-signed build makes `AudioHardwareCreateProcessTap` **succeed and return silence** — no error to catch, so "degrade on tap-creation-failure" won't fire. Detection is a **first-class, tested requirement**: combine (a) OSStatus checks on every Core Audio call, (b) "received any buffers within N seconds," and (c) level-based (not segment-count-based) silence detection. The permission-card heuristic must not equate "system was legitimately silent" with "permission denied."
- **Build caveat (mandatory QA):** TCC prompt fires only on a **stably code-signed** binary; ad-hoc/`xcodebuild` builds silently deliver silence. First QA step is a signed smoke test; documented in `BUILDING.md`.

---

## Timestamps & Speaker Labeling

**Speaker labels are ground-truth by source, not ML.** mic → "Me", system tap → "Them", assigned at the source level (`AudioSourceRecord.role`), never per-segment classification. Zero DER, zero models.

**Segment timestamps — reuse whisper's discarded output.** whisper.cpp already sets `params.print_timestamps = true` (LibWhisper.swift:61) and computes `whisper_full_get_segment_t0/t1`; `getTranscription()` (LibWhisper.swift:104) throws them away. New `getTimestampedSegments()` reads them. **Unit trap (verified):** whisper.cpp's `t0/t1` are in **centiseconds** → multiply by `0.01` for seconds; comment the unit in code and confirm empirically against a golden WAV.

**VAD time-base — RESOLVED, and it is a correctness gate, not a footnote (§critique A2 / #4).** `LibWhisper.fullTranscribe` enables whisper's internal VAD when the user's `IsVADEnabled` default is set (LibWhisper.swift:73-88). With `params.vad = true`, whisper trims silence *before* transcription, so `whisper_full_get_segment_t0/t1` are relative to the **VAD-trimmed** audio, not the original WAV. A per-stream constant `t0Offset` **cannot** undo a non-linear intra-stream time warp — and because the mic and system streams have *different* silence distributions, their warps differ, so the interleaved order in the exact turn-taking case the feature exists for would be wrong. **Decision: disable whisper-internal VAD on the multi-source transcription path** so segment times map to the raw WAV timeline (accepting slower transcription). This is verified in the **blocking Phase 1 golden-WAV spike** ("does whisper populate t0/t1 in original-WAV time under our settings?") as a go/no-go gate before Phase 2, not a nice-to-have.

**Interleave algorithm (N-source-ready, used with 2).** Each source's whisper segments are 0-based within its own WAV. Per-segment text is filtered/formatted/word-replaced first; then shift by that source's `t0Offset`, `flatMap`, sort by adjusted start:
```
merged = sources
  .flatMap { s in s.segments.map { seg in
      TranscriptSegment(speaker: s.role,
                        text:  clean(seg.text),          // filter/format/word-replace HERE
                        start: seg.start + s.t0Offset,
                        end:   seg.end   + s.t0Offset) } }
  .sorted { $0.start < $1.start }
```
Then compose the flat labeled payload from the *cleaned* segments: `"[mm:ss] Me: …\n[mm:ss] Them: …"`.

**Filter corruption — RESOLVED (§critique #1, the other critical one).** The existing `TranscriptionOutputFilter` (TranscriptionOutputFilter.swift:7-13, invoked at TranscriptionPipeline.swift:76) strips anything in square brackets via `#"\[.*?\]"#`, then collapses whitespace and trims — it would **delete every `[mm:ss]` prefix and flatten the `\n` speaker layout**. The naive "just reuse the existing chain on the flat text" is therefore not viable. **Fix:** the multi-source branch runs filter/format/word-replace **per-segment on raw segment text** (before composition), then builds the labeled flat text from already-cleaned segments — the composed `[mm:ss]`-prefixed string never passes through the bracket-stripping filter.

**Enhancement mangling — RESOLVED (§critique A3).** Feeding the labeled, timestamp-prefixed string into `enhancementService.enhance` (TranscriptionPipeline.swift:114-130) lets the LLM reflow/merge/strip `[00:07] Me:` prefixes and rewrite "Them" lines as the user's own dictation — producing a **split-brain** where History shows a clean conversation but the pasted text is a mangled blob. **Policy for v1:** AI enhancement on the multi-source path is **off by default** with a clear settings note; when a user opts in, enhancement runs **per-speaker-turn** and the flat `text` used for paste is **regenerated from the (possibly enhanced) segments**, never left as a free-form LLM blob. "Accept minor drift" applies only to word-replacement, not to LLM rewriting of structured multi-speaker data.

**Accuracy caveat (documented).** With VAD disabled, segment times track the raw WAV linearly, so cross-source ordering is correct; timestamps remain **approximate at segment (~sentence) granularity**. Word-level accuracy is out of scope. "Them" collapses multiple remote speakers into one label (a 3-person Zoom is one output stream → one "Them") — an inherent architectural limit stated in Settings copy, not a bug; ML diarization is reserved for Phase 6.

---

## Data Model & Migration

**v1 change — two additive optional scalar fields on `Transcription`:**
```swift
var segmentsJSON: String?      // JSON [TranscriptSegment] — the merged labeled transcript
var audioSourcesJSON: String?  // JSON [AudioSourceRecord] — per-source WAV + t0Offset + role
```

**Why JSON blobs, not `@Relationship`.** The schema has **zero** relationships and **no** `VersionedSchema`/`SchemaMigrationPlan` — it relies entirely on automatic lightweight migration. Additive optional `String?` fields are the only category proven safe under lightweight migration without precedent, and they match the existing `prioritizedDevicesData` Codable precedent. Introducing the first-ever relationship simultaneously with the first multi-source feature stacks two unvalidated risks. The UX lens's `@Relationship` design is documented as the Phase-6 target.

**Value types (Codable, not `@Model` in v1):**
- `TranscriptSegment { speaker: String; text: String; start/end: TimeInterval }` (Codable, Hashable).
- `AudioSourceRecord { role: String; fileURL: URL; t0Offset: TimeInterval; deviceName: String?; processBundleID: String? }` — field-compatible with the future `@Model`.

**Backward compatibility.**
- `text` = flattened merged transcript → search predicates, copy/paste, History preview, CSV export all keep working.
- `audioFileURL` = **mic** WAV (primary/legacy) → all 26 single-URL call sites (cleanup, player, export, deletion) keep working; per-source files are additive.
- Old rows have `segmentsJSON == nil` → UI falls back to the existing flat Original/Enhanced rendering. **Imported-file and retranscribed rows also set `segmentsJSON == nil`** and hit the same fallback — but because they share the modified detail/list/result views, they go in the regression matrix (§critique D1).

**Migration approach.** Additive optional scalars → automatic lightweight migration, no manual plan. **Blocking Phase 0 spike (§critique D2):** test the *round-trip* — (1) populated old store → launch new build → old rows render via fallback, new rows render segmented, no crash; (2) create a new two-source row → **downgrade to the old build → confirm no crash on the unknown fields** (beta-channel users do downgrade). Register nothing new in the `ModelContainer` schema.

**Documented future path (Phase 6).** Once a feature needs to *query over* segments/speakers ("everything Them said"), introduce `VersionedSchema` + `SchemaMigrationPlan`, promote the blobs to `@Model TranscriptSegment` / `AudioSourceRecord` with `@Relationship(deleteRule: .cascade)`, backfilling from JSON.

---

## Files to Add / Modify

Paths are real, grouped by layer.

### Capture layer
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Services/MultiSource/RecordingTimeline.swift` | **New** | RT-safe atomic `mHostTime` anchor set pre-start; `offsetSeconds(forHostTime:)`; host-valid-flag fallback to `mach_absolute_time()`; sole cross-stream guardrail. |
| `VoiceInk/Services/MultiSource/SystemAudioTapRecorder.swift` | **New** | `@available(macOS 14.4,*)` process-tap (self-excluded) → private aggregate → `AudioDeviceCreateIOProcIDWithBlock`; RT-safe `ExtAudioFileWrite`; own 16k/mono/Int16 WAV; records `sourceT0Offset`; OSStatus + buffer-arrival checks. |
| `VoiceInk/Services/MultiSource/PCMConverter.swift` | **New** | Downmix + resample-to-16k/mono/Int16 extracted from `CoreAudioRecorder.convertAndWriteToFile` (~631-713), pre-allocated buffers; shared by both recorders. |
| `VoiceInk/Services/MultiSource/DualSourceRecorder.swift` | **New** | `@MainActor` coordinator; pre-start `mach_absolute_time()` anchor; owns mic `Recorder` + tap + `RecordingTimeline`; **suppresses mute/pause**; degrades to mic-only on tap failure; cancel deletes both WAVs. |
| `VoiceInk/CoreAudioRecorder.swift` | **Mod** | *Additive only:* capture `inTimeStamp.mHostTime` (with host-valid fallback) in `handleInputBuffer`, store lock-free into optional atomic timeline; store `sourceT0Offset`. No behavior change when timeline is unset. |

### Transcription layer
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Models/TranscriptSegment.swift` | **New** | `Codable, Hashable` value type `{ speaker, text, start, end }`. Not a `@Model` in v1. |
| `VoiceInk/Models/AudioSourceRecord.swift` | **New** | `Codable, Hashable` `{ role, fileURL, t0Offset, deviceName?, processBundleID? }`; N-ready. |
| `VoiceInk/Whisper/LibWhisper.swift` | **Mod** | Add `getTimestampedSegments()` reading `whisper_full_get_segment_t0/t1` (**×0.01 centisec→sec**, comment the unit) alongside text. Add a **VAD-disabled** entry for the multi-source path. `getTranscription()` byte-identical. |
| `VoiceInk/Services/LocalTranscriptionService.swift` | **Mod** | Add `transcribeWithSegments(audioURL:model:) -> [(start,end,text)]` on the VAD-disabled path. Existing `transcribe(...) -> String` untouched; no `TranscriptionService` protocol change (avoids touching 5 conformers). |
| `VoiceInk/Services/MultiSource/TranscriptMerger.swift` | **New** | N-source `merge(sources:)`: per-segment clean (filter/format/word-replace) → shift by `t0Offset` → `flatMap` → sort. Pure, unit-testable. |

### Orchestration + pipeline
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Whisper/VoiceInkEngine.swift` | **Mod** | Add `dualSourceRecorder`; gate on `TwoSourceTranscriptionEnabled` **&& effective (PowerMode-resolved) local model** — re-checked after `ActiveWindowService.applyConfiguration` (runs ~line 152, after recording start). Start branch (~line 119): two UUID WAV URLs; start coordinator. Stop branch (~line 84): per-source segment transcription, merge, build `Transcription`, route through multi-source pipeline branch. Cancel branch deletes both temp WAVs. Flag off → existing path unchanged. |
| `VoiceInk/Whisper/TranscriptionPipeline.swift` | **Mod** | Add a **multi-source branch** taking pre-cleaned `[TranscriptSegment]`: **skips** `TranscriptionOutputFilter` (bracket-strip); composes flat `text` from cleaned segments; enhancement off-by-default (or per-turn, regenerating `text` from segments); then save → `CursorPaster.pasteAtCursor` → `onDismiss`. `segmentsJSON` stored as immutable artifact. `RecordingState` unchanged. |

### Data model + persistence
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Models/Transcription.swift` | **Mod** | Add `var segmentsJSON: String?`, `var audioSourcesJSON: String?` (additive optional). Add computed `isMultiSource`/`hasSegments`. Existing fields unchanged. |
| `VoiceInk/Services/TranscriptionAutoCleanupService.swift` | **Mod** | On delete, decode `audioSourcesJSON`, delete each source WAV. |
| `VoiceInk/Views/Settings/AudioCleanupManager.swift` | **Mod** | Shared `allAudioFileURLs(for:) -> [URL]` helper so per-source WAVs are non-orphaned. |
| `VoiceInk/Views/History/TranscriptionHistoryView.swift` | **Mod** | Deletion path (~382-399) uses `allAudioFileURLs(for:)`. |

### UI
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Views/ConversationTranscriptView.swift` | **New** | Renders `[TranscriptSegment]` as interleaved per-speaker-tinted rows `[mm:ss] Me:`; groups consecutive same-speaker; `.textSelection(.enabled)`; "Copy full conversation." |
| `VoiceInk/Views/History/TranscriptionDetailView.swift` | **Mod** | If `hasSegments`, render `ConversationTranscriptView`; else Original/Enhanced bubbles. Single `AudioPlayerView` on mic WAV. |
| `VoiceInk/Views/TranscriptionResultView.swift` | **Mod** | Conversation view as primary state when `hasSegments`. |
| `VoiceInk/Views/History/TranscriptionListItem.swift` | **Mod** | Multi-source rows get a "**N speakers**" badge derived from `audioSourcesJSON` count (not hardcoded "2" — §critique F). |
| `VoiceInk/Views/History/TranscriptionMetadataView.swift` | **Mod** | "Sources" section from `audioSourcesJSON` when present. |
| `VoiceInk/Views/Settings/AudioInputSettingsView.swift` | **Mod** | "System Audio" section: `Toggle` on `TwoSourceTranscriptionEnabled`, explainer, local-model + capture-permission note, **and the "keeps other apps playing/audible" note**; inline amber "Grant audio capture access" when TCC not granted. |

### Permissions / entitlements / build
| File | New/Mod | Change |
|---|---|---|
| `VoiceInk/Info.plist` | **Mod** | Add `NSAudioCaptureUsageDescription`. |
| `VoiceInk/VoiceInk.entitlements` | **Verify** | Confirm `com.apple.security.device.audio-input` (lines 19-20); unsandboxed → no new key. |
| `VoiceInk/VoiceInk.local.entitlements` | **Verify** | Keep in sync; no new key expected. |
| `VoiceInk/Views/PermissionsView.swift` | **Mod** | Add "System Audio Capture" `PermissionCard` + `@Published isSystemAudioCaptureEnabled` (heuristic: OSStatus-success + buffers-arrived, not silence-equals-denial). |
| `BUILDING.md` | **Mod** | TCC prompt fires only on stably code-signed builds; ad-hoc/`xcodebuild` deliver silence. Document the `@available(macOS 14.4,*)` requirement and which pbxproj config ships. |

**Not touched:** `OnboardingPermissionsView.swift` (opt-in, just-in-time), `VoiceInkCSVExportService.swift` (flat `text` carries the labeled transcript), the `TranscriptionService` protocol + its 5 conformers, all streaming providers. **On the regression radar (shared code, single-source consumers):** imported-file / retranscribed transcriptions via `AudioFileTranscriptionManager` / `AudioFileTranscriptionService` — they render through the modified detail/list/result views and must be in the test matrix.

---

## UI

- **Settings (Phase 4 → 5).** *Phase 4:* "System Audio" section in `AudioInputSettingsView` — toggle on `TwoSourceTranscriptionEnabled`, explainer, local-model + capture-permission note, mute/pause-disabled note, inline TCC affordance. *Phase 5:* promote to a dedicated `.audioSources` ViewType + `AudioSourcesSettingsView` + `SystemAudioCaptureManager` with an add-mic/add-app/add-system list, per-source name+color, live availability pill, backed by a `Codable [AudioSourceConfig]` blob in `UserDefaultsManager`.

- **Recorder.** When >1 active source, the mini/notch panels render one compact **level bar per source**, tinted + short-labeled ("Me"/"Them"), reusing the existing RMS/peak → EMA → `AudioMeter` machinery. A **level-based** (not segment-count) "no audio" hint fires after a few seconds so a dead source (unsigned build, muted app, device-change silence) is visible and fixable mid-recording. Single-source renders exactly today's waveform. `RecordingState` unchanged.

- **History / detail.** `ConversationTranscriptView` for `hasSegments` rows; Original/Enhanced fallback otherwise. Single `AudioPlayerView` on the mic WAV (multi-track + tap-to-seek deferred to Phase 6). "N speakers" list badge; "Sources" metadata section.

- **Result popup.** Conversation view as the primary state when `hasSegments`. Because two sequential local passes double latency, the "transcribing" state must show honest per-source progress and never appear hung (§critique #7 / E).

- **Export.** v1: no change — flat `text` already carries the labeled transcript in the existing CSV column. Deferred (Phase 6): "Export Conversation" → Markdown (`[mm:ss] Speaker: text`) and WebVTT/SRT (segments → cues with `<v Speaker>`).

---

## Edge Cases & Risks

**Correctness blockers (must be resolved before Phase 4 ships):**
1. **Filter destroys `[mm:ss]` (§#1)** — the multi-source pipeline branch bypasses `TranscriptionOutputFilter`; per-segment cleaning happens pre-composition. **Resolved in design.**
2. **VAD warps intra-stream timestamps (§A2/#4)** — VAD disabled on the multi-source path; verified by the blocking Phase 1 golden-WAV spike as a go/no-go gate. **Resolved in design; empirically gated.**
3. **Mute/pause self-collision (§A1)** — `DualSourceRecorder` suppresses both when active. **Resolved in design; QA-gated.**
4. **Enhancement mangles labeled text (§A3)** — enhancement off-by-default / per-turn, flat `text` regenerated from segments. **Resolved in design.**

**Capture/alignment risks (mitigated):**
5. **`mHostTime`-only alignment; host-valid flag may be unset (§#2)** — pre-start explicit anchor + `mach_absolute_time()` fallback + non-zero-offset assertion; RT-safe atomic. Never compare `mSampleTime`.
6. **Self-audio contamination (§#3)** — tap excludes own process object; §5 and code reconciled.
7. **Default-output device change mid-record (§#5)** — rebuild aggregate/tap around new device; empirical confirmation of IOProc behavior is a blocking QA item; level-based "no audio" hint as backstop.
8. **Silent failure on unsigned builds (§#2/#6/B2)** — first-class detection: OSStatus checks + buffers-arrived-within-N-seconds + level-based silence, not "tap-creation-failure." Signed smoke test first QA step.
9. **RT-safety of host-time capture + `AVAudioFile.write` (§F/#9)** — atomic host-time store; `ExtAudioFileWrite` with pre-allocated buffers; no allocation/locks/ARC on the audio thread.
10. **`@available` / deployment-target mismatch (§F)** — all `MultiSource` code guarded `@available(macOS 14.4,*)`; confirm shipping pbxproj config.

**Behavioral/perf risks:**
11. **2× sequential latency, not just battery (§#7/E)** — whisper `actor` serializes the two passes → ~2× stop→result wall-clock; N sources → N× at Phase 5. Surfaced in progress UI; documented as a Phase-5 ceiling; not sold as free.
12. **PowerMode swaps to a cloud model mid-session (§B4)** — `applyConfiguration` runs after recording starts; the gate is re-checked against the **effective** model post-resolution. If PowerMode forces cloud while two-source is on, the coordinator degrades to single-source (cloud can't produce segments) rather than producing two orphan WAVs.
13. **"Them" collapses multiple remote speakers** — inherent limit; honest Settings copy; ML tier is Phase 6.
14. **whisper populates `t0/t1` meaningfully?** — verified in the Phase 1 golden-WAV spike (segment-level, `print_timestamps=true` already set; no `token_timestamps` needed).

**Edge cases to handle explicitly:** "Them" starts before "Me" (merge interleaves correctly — unit-tested); tap fails to start → completes as single-source (mic); empty system stream → "Them" has zero segments, transcript is just "Me" (distinguished from *capture failure* via level, not segment count — §B3); **cancel-before-save deletes both temp WAVs** (§B5); deletion removes all per-source WAVs; old/imported/retranscribed (`nil`-`segmentsJSON`) rows render via fallback; both recorders emit valid 16k/mono/Int16 WAVs readable by `LocalTranscriptionService.readAudioSamples` (44-byte header skip); output-device change mid-record does not crash and preserves already-captured audio.

---

## Testing Strategy

- **Unit tests.** `TranscriptMerger`: interleave with "Them"-before-"Me", overlapping turns, zero-segment source, N>2. `RecordingTimeline`: offset math with valid/invalid host-time flag, pre-start anchor correctness. `TranscriptSegment`/`AudioSourceRecord` Codable round-trips. Per-segment cleaning preserves segment boundaries (no bracket loss).
- **Blocking spikes (gate progress):**
  - *Phase 0 migration spike* — forward load + **downgrade** round-trip against a populated `default.store`.
  - *Phase 1 golden-WAV timestamp spike* — confirm `t0/t1` are original-WAV-time under the VAD-disabled path (go/no-go for Phase 2).
- **Integration (signed build only).** Two-WAV capture with stable, plausibly-small `mHostTime` offsets; self-exclusion (VoiceInk's own sounds absent from "Them"); mute/pause suppressed with both defaults ON (media keeps playing, "Them" non-silent); output-device switch mid-record (no crash, hint fires); tap-creation-failure → mic-only; unsigned-build silent-failure detection.
- **Pipeline correctness.** Verify pasted/persisted `text` retains `[mm:ss]` prefixes and speaker layout (regression against the filter bug); enhancement-off produces faithful conversation; enhancement-on (per-turn) regenerates `text` from segments without split-brain.
- **Regression matrix (single-source unchanged).** Classic dictation, streaming providers, cloud models, **imported-file and retranscribed** transcriptions (share the modified views), PowerMode model-swap gating, History/detail/result/CSV export for legacy `nil`-`segmentsJSON` rows.
- **QA gates (must pass before shipping Phase 4):** signed smoke test (TCC prompt fires); mute/pause suppression; filter/enhancement faithfulness; device-change non-fatality.

---

## Open Questions for the User

1. **MVP scope confirmation (critical — please confirm before work starts).** The MVP delivers exactly **mic + global system audio, "Me"/"Them"**. Three of the six originally requested capabilities — **per-app selection**, **multiple mics**, and **configurable-N sources** — are all deferred to Phase 5 (the harder half: process enumeration, per-app tap lifecycle, a new settings surface). Is "mic + system, exactly 2, for v1" acceptable, or should per-app / multi-mic be pulled earlier at the cost of a later first ship?

2. **AI enhancement on multi-speaker transcripts.** Preferred default: enhancement **off** for two-source recordings (faithful conversation, no LLM reflow risk), with opt-in per-turn enhancement? Or should enhancement be on with a conversation-aware prompt from day one?

3. **VAD trade-off.** Disabling whisper-internal VAD on the multi-source path is required for correct cross-source timestamps but makes those passes slower. Acceptable, or do you want to explore the more expensive external-VAD-with-trim-map option in v1?

4. **Latency expectation.** Two-source transcription is ~2× the single-source stop→result wait (sequential whisper passes). Acceptable for the MVP, or should we invest in parallel contexts / streaming-of-the-mic-track to hide it?

5. **Device-change behavior in v1.** Full aggregate rebuild on output-device change (more code, robust) vs. detect-and-warn-with-live-hint (less code, may lose the "Them" track until restart) — which do you want for the first ship?

6. **Empirical unknowns to confirm during Phase 0/1 (informational).** Exact TCC behavior on the target macOS version (distinct System Settings toggle? any preflight API?); whether the vendored whisper.cpp populates `segment_t0/t1` in original-WAV time under our settings; whether the PowerMode `AppPicker.swift` pattern is reusable for the Phase 5 per-app picker.

---

## Architecture & Extensibility Addendum

*Additive architecture/extensibility lens (the third design lens, generated separately). Refinements only — does not restate the MVP/UX plan. Verified against `Recorder.swift`, `CoreAudioRecorder.swift`, `TranscriptionService.swift`, `TranscriptionServiceRegistry.swift`, `Transcription.swift`, `VoiceInkEngine.swift`. Each item says whether to do it in **v1** or defer.*

### 1. Introduce a minimal `CaptureSource` protocol in v1 (control plane only, off the RT path)

Both capture types are structurally divergent today: the mic path is `Recorder.startRecording(toOutputFile:) async` (@MainActor, reads `AudioDeviceManager.getCurrentDevice()` internally), `CoreAudioRecorder.startRecording(toOutputFile:deviceID:)` is sync + device-parameterized, and `SystemAudioTapRecorder` is a third shape. Without a protocol, the coordinator hard-codes `let mic` + `let tap` and every Phase-5 source type forces edits to its start/stop/degrade/cancel fan-out. A protocol collapses that to array iteration — the thing that actually makes the coordinator N-ready.

```swift
@MainActor
protocol CaptureSource: AnyObject {
    var role: String { get }                       // "Me" / "Them" / future per-source name
    var meter: AudioMeter { get }                  // per-source level bars + "no audio" hint
    func start(toOutputFile url: URL, timeline: RecordingTimeline) async throws  // writes 16k/mono/Int16 WAV
    func stop() async
    func makeSourceRecord() -> AudioSourceRecord    // { role, fileURL, t0Offset, deviceName?, processBundleID? }
}
```
Wrap the existing mic `Recorder` behind a thin `MicCaptureSource` adapter (do **not** widen `Recorder` itself). The protocol is `@MainActor` and lives entirely on the control plane — it says nothing about the RT callback, so it does not risk the audio-capture real-time rules. **v1.** New file `VoiceInk/Services/MultiSource/CaptureSource.swift`.

### 2. Rename `DualSourceRecorder` → `MultiSourceCaptureCoordinator([CaptureSource])` now

The name and `let mic/let tap` shape bake N=2 into the one component the merger's N-readiness depends on to be fed. `init(sources: [CaptureSource], timeline: RecordingTimeline)`; `start()` snapshots the single `mach_absolute_time()` anchor then `await`s each source; `stop()` returns `[AudioSourceRecord]`; degradation generalizes to "drop sources that failed to start, proceed if ≥1 survives." **Important:** gate mute/pause suppression on **"any source is a system/app tap"**, not on the `TwoSourceEnabled` bool — a two-*mic* session should NOT suppress system mute, a distinction the bool can't express. **v1.**

### 3. Add a narrow `SegmentingTranscriptionService` protocol instead of concrete-only

The plan's concrete-only `transcribeWithSegments` on `LocalTranscriptionService` makes the engine reach for `serviceRegistry.localTranscriptionService` by concrete type — re-introducing the routing coupling the registry exists to hide, and giving Phase-6 cloud diarization (Deepgram/Soniox) no seam.

```swift
protocol SegmentingTranscriptionService: TranscriptionService {
    func transcribeWithSegments(audioURL: URL, model: any TranscriptionModel) async throws -> [TranscriptSegment]
}
```
Only `LocalTranscriptionService` conforms in v1 (its `transcribe -> String` stays byte-identical). Add `registry.segmentingService(for:) -> (any SegmentingTranscriptionService)?` returning `service(for:) as? SegmentingTranscriptionService`. The engine asks the registry and falls back to single-source on `nil` — which *is* the plan's PowerMode-swapped-to-cloud degrade (§B4), now one uniform `as?` instead of a concrete special-case. Phase 6 conforms a cloud service with zero engine changes. **v1.**

### 4. Version the persisted blob (uphold JSON-over-`@Relationship` for v1)

The plan's JSON-blob call is architecturally correct — do not introduce the schema's first-ever relationship alongside the first multi-source feature. One hedge: persist a versioned envelope, not a bare array, so the Phase-6 relationship backfill becomes a `switch schemaVersion` instead of shape-guessing.
```swift
struct MultiSourceTranscript: Codable { var schemaVersion: Int; var segments: [TranscriptSegment]; var sources: [AudioSourceRecord] }
```
Costs one `Int`; stays an additive optional `String?` field (same migration category). **v1.**

### 5. Land `AudioSourceConfig` + `CaptureSourceFactory` in v1 (hard-coded configs)

The plan scopes `AudioSourceConfig` to Phase 5, so the v1 engine constructs `[MicCaptureSource, SystemAudioTapRecorder]` inline inside the dense `Task` in `toggleRecord`'s start branch (~lines 130-180) — the highest-risk file for Phase 5 to churn. A factory moves all source-kind knowledge out of the engine now.
```swift
enum AudioSourceKind: Codable, Hashable { case microphone(deviceUID: String?); case systemGlobal; case app(bundleID: String) }
struct AudioSourceConfig: Codable, Hashable { var kind: AudioSourceKind; var role: String }
```
`CaptureSourceFactory.makeSources(from: [AudioSourceConfig]) -> [CaptureSource]`; v1 feeds a hard-coded 2-element array, Phase 5 feeds a decoded array from `UserDefaultsManager`. The engine calls `factory.makeSources(...)` then the coordinator — never naming a concrete capture type again. **Persist device UIDs, not `AudioDeviceID`/name**, per the audio-capture skill (IDs are unstable across reconnects) — a detail `AudioSourceRecord.deviceName` alone doesn't satisfy for saved configs. **Types + factory: v1. Settings UI + persistence: Phase 5.**

### 6. Residual risks

- **God-object growth in `VoiceInkEngine`.** The plan adds per-source transcription + merge + multi-source `Transcription` assembly to `toggleRecord`'s stop-branch (lines 84-118), already large. Put the "N WAVs → `[TranscriptSegment]` → merged `Transcription`" logic in `TranscriptMerger`/a small `MultiSourceAssembler`; keep the engine stop-branch a thin branch selector. **v1 (decide the boundary now).**
- **Coordinator testability.** A `CaptureSource` protocol makes the coordinator unit-testable with a `FakeCaptureSource` (assert anchor-before-start, degrade-on-throw, cancel-deletes-all-WAVs) — impossible against concrete hardware types. Closes a gap: the plan unit-tests `TranscriptMerger`/`RecordingTimeline` but has no coordinator unit test. **v1.**
- **Threading.** Keep `CaptureSource` `@MainActor` (control plane); the RT block must still write host-time into `RecordingTimeline` via the lock-free atomic the plan specifies — the protocol must not tempt an implementer to call a `@MainActor` witness from the callback. Rule, not code.

### Net changes to the plan
- Add `CaptureSource.swift` + `MicCaptureSource` adapter; rename `DualSourceRecorder` → `MultiSourceCaptureCoordinator([CaptureSource])`; mute-suppression predicate becomes "any tap source present." (v1)
- Add `SegmentingTranscriptionService: TranscriptionService` routed via `registry.segmentingService(for:)`; removes the engine's concrete-service reach; Phase-6 cloud-diarization seam. (v1)
- Persist a versioned `MultiSourceTranscript { schemaVersion, segments, sources }` envelope; keep JSON-over-relationship. (v1)
- Land `AudioSourceConfig` + `CaptureSourceFactory` (hard-coded v1); persist device **UIDs**; Phase-5 adds factory cases + UI, never edits the engine. (v1 types/factory)
- Extract multi-source `Transcription` assembly out of `VoiceInkEngine` into the merger/assembler. (v1)