---
date: 2026-07-01
type: feat
scope: multi
title: Conversation Mode Phase 6 — multi-track playback + Markdown/VTT/SRT export
---

## What changed

Multi-source conversation recordings can now be **played back as synchronized tracks** and
**exported** as Markdown, WebVTT, or SubRip.

- **Playback:** History detail renders a `MultiTrackPlayerView` for multi-source rows — one
  tinted waveform lane per source (inset by its `t0Offset`), a shared playhead, and
  tap/drag-to-seek on the shared timeline. Driven by a new `MultiTrackPlayer` (`AVAudioEngine`,
  one `AVAudioPlayerNode` per source, all started against a single host-time anchor so tracks
  stay sample-locked; seek = stop-all + reschedule-all; missing source files degrade
  gracefully). Single-source rows keep the existing `AudioPlayerView` unchanged.
- **Export:** new `Services/Export/` module — pure `MarkdownTranscriptSerializer`,
  `VTTTranscriptSerializer`, `SRTTranscriptSerializer` (+ `TranscriptExportFormat` timecode/
  filename helpers) and `MultiSourceExportService`. The Save button (`AnimatedSaveButton`) now
  routes Markdown through the conversation serializer and offers **VTT/SRT for multi-source
  rows**; TXT/MD stay for all rows. Pure serializers are unit-tested.

## Why

Users want to hear a captured conversation with both sides aligned, and to export a
timestamped, speaker-labeled transcript for subtitles or documents.

## Impact

- Users: multi-track playback + tap-to-seek in History detail; export a conversation as
  Markdown/VTT/SRT from the Save menu. Single-source behavior unchanged.
- Subsystems: playback, export, History UI. No schema/migration/entitlement changes.
- Breaking: no.

## Decision: SwiftData relationship migration DEFERRED

Promoting `segmentsJSON`/`audioSourcesJSON` to first-class `@Model` relationships was
**deferred** (documented GO-plan in `docs/plans/phase6-implementation-spec.md` §1). Rationale:
no Phase 6 feature queries across segments/sources (playback + export both read the decoded
blobs in memory), and introducing the store's first relationship + first custom migration adds
real corruption/downgrade risk to users' transcription history for zero current benefit. The
JSON envelope (`MultiSourceTranscript.schemaVersion`) was designed to make that migration a
one-time backfill whenever a query-over-segments feature actually lands.

## Not verified on-device

Playback sync/seek and export round-trips (loading VTT/SRT into a subtitle-aware player) need a
real multi-source recording + audio device — see `docs/plans/phase6-implementation-spec.md` §4.3.

## References

- Spec: `docs/plans/phase6-implementation-spec.md`
- Branch: `feature/multi-source-transcription`
