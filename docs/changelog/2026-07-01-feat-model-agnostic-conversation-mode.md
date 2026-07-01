---
date: 2026-07-01
type: feat
scope: transcription
title: Conversation Mode is model-agnostic — Parakeet now segment-capable
---

## What changed

Conversation Mode (multi-source transcription) no longer requires a local whisper model.
`ParakeetTranscriptionService` now conforms to `SegmentingTranscriptionService`: it exposes
FluidAudio's token-level timings, which a new pure `ParakeetSegmentGrouper` groups into
timestamped segments (pause-based splitting, SentencePiece normalization). The engine's
multi-source gate now asks the registry for *any* segment-capable service
(`segmentingService(for:) != nil`) instead of hard-coding `provider == .local`.

## Why

Users with only Parakeet selected got a silent fallback to single-mic dictation — Conversation
Mode looked enabled but captured "only myself". The architecture was already model-agnostic
(run the selected model once per source WAV, interleave by timestamp); only the gate and the
missing conformance blocked it.

## Impact

- Users: Conversation Mode now works with Parakeet models, not just local whisper.
- Subsystems: transcription (Parakeet service, engine gate); `ParakeetSegmentGrouper` is
  unit-tested (`ParakeetSegmentGrouperTests`, Swift Testing).
- Breaking: no.
- Permissions/entitlements added or changed: none.
