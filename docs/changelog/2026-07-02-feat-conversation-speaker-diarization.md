---
date: 2026-07-02
type: feat
scope: multi
title: Opt-in on-device speaker diarization for Conversation Mode
---

## What changed

Conversation Mode can now split the system-audio side of a recording into distinct voices:
a new "Detect multiple speakers (beta)" toggle (Settings → Audio Input) runs FluidAudio's
on-device diarizer over non-mic tracks and relabels their segments "Speaker 1/2/…", numbered
by first appearance on the shared timeline. Speakers can be renamed from the transcript's
context menu; renames rewrite `segmentsJSON` and recompose the stored flat text so previews,
search, and every export stay consistent. The mic track keeps its ground-truth "Me" label,
and a track with only one detected voice keeps its plain role (no "Speaker 1" noise on 1:1
calls).

## Why

A meeting captured via the system-audio tap arrives pre-mixed — every remote participant
collapsed into one "Them". Diarization is the only on-device way to attribute individual
remote voices (research: docs/plans/meeting-diarization-spec.md).

## Impact

- Users: new opt-in toggle; diarized transcripts show renamable "Speaker N" labels; a small
  model downloads on first enable. Audio never leaves the Mac.
- Subsystems: multi (MultiSource services, Transcription model, history/settings UI, engine
  warm-up). Transcript pipeline loads diarizer models cache-only — never network in-pipeline.
- Breaking: no (`TranscriptSegment.clusterId` is additive-optional; v1 rows decode unchanged).
- Permissions/entitlements added or changed: none.
