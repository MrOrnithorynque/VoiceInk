---
date: 2026-07-01
type: feat
scope: multi
title: Multi-source (mic + system audio) timestamped, speaker-labeled transcription (MVP)
---

## What changed

Added an opt-in "Conversation Mode" that records the microphone ("Me") and system/other-app
audio ("Them") simultaneously and produces one interleaved, timestamped, speaker-labeled
transcript (`[00:07] Me: … / [00:12] Them: …`). Speaker identity is ground-truth by capture
source — no ML diarization. Enable it in Settings → Audio Input → "System Audio (Conversation
Mode)"; it runs only with a local model (Whisper/Parakeet) and on macOS 14.4+.

New subsystem under `VoiceInk/Services/MultiSource/`: a `CaptureSource` protocol with
`MicCaptureSource` (drives `CoreAudioRecorder` directly, so the single-source `Recorder`
mute/pause path is never triggered) and `SystemAudioTapRecorder` (Core Audio process tap →
private aggregate → IOProc, self-excluding VoiceInk). A `MultiSourceCaptureCoordinator` time-
aligns N sources on one `mach_absolute_time()` anchor; `TranscriptMerger` (pure, unit-tested)
interleaves per-source whisper segments by adjusted start; the `TranscriptionPipeline`
multi-source branch persists segments and pastes the flat labeled text.

## Why

Users asked to transcribe conversations (calls, meetings, interviews) capturing both their own
voice and the other party's system audio, with who-spoke-when timestamps.

## Impact

- Users: new opt-in Conversation Mode. During recording the mini/notch recorder shows a live
  tinted level bar per source ("Me"/"Them") with a "no audio detected" hint; the result popup
  and History detail render an interleaved conversation view; History detail adds an "Audio
  Sources" section and the list shows a "N speakers" badge; Settings → Permissions adds a
  "System Audio Capture" card. Single-source dictation is unchanged.
- Subsystems: audio capture, transcription (new `SegmentingTranscriptionService` + VAD-off
  `getTimestampedSegments`), engine/pipeline, persistence, UI.
- Breaking: no. `Transcription` gains two additive optional fields (`segmentsJSON`,
  `audioSourcesJSON`); legacy/imported rows have them nil and render the classic view.
- Permissions/entitlements: adds `NSAudioCaptureUsageDescription` to Info.plist. No new
  entitlement (app is unsandboxed and already has `device.audio-input`). First use prompts for
  Audio Recording permission.

## Design decisions (v1)

- AI enhancement is **off** for multi-source transcripts (avoids LLM reflowing the labeled
  layout); whisper VAD is **disabled** on this path (so segment times map to the raw WAV, for
  correct cross-source ordering) at the cost of ~2× (sequential) transcription latency.
- Correctness traps handled: the bracket-stripping `TranscriptionOutputFilter` is bypassed
  (cleaning is per-segment before composing `[mm:ss]` text); the mute/pause self-collision is
  avoided by construction (multi-source never touches MediaController).

## Not yet (follow-ups)

Per-app selection, multiple mics, and configurable-N sources (Phase 5); `@Relationship`
migration, multi-track playback, and VTT/SRT export (Phase 6). On-device validation still
required: signed-build TCC smoke test, tap-delivers-audio, output-device-change behavior, and
the SwiftData downgrade round-trip. See `docs/plans/multi-source-transcription-plan.md`.

## References

- Plan: `docs/plans/multi-source-transcription-plan.md`
- Branch: `feature/multi-source-transcription`
