---
date: 2026-07-01
type: feat
scope: multi
title: Conversation Mode Phase 5 — configurable N sources (per-app audio, multiple mics)
---

## What changed

Conversation Mode is no longer limited to mic + global system audio. A new "Custom" mode
(Settings → Audio Input, when Conversation Mode is on) lets the user compose up to 4 audio
sources: a microphone by specific device, additional microphones, a specific app's audio
(picked from a list of running audio apps), and/or global system output — each with an editable
speaker label, reorderable, removable. The configured list drives capture, transcription, and
the merged labeled transcript.

New: per-app Core Audio tap (`CATapDescription(stereoMixdownOfProcesses:)` via a mode on
`SystemAudioTapRecorder`), `AudioProcessEnumerator` (lists/​resolves audio processes),
`CoreAudioUtils` (shared helpers), `AudioSourcesSettingsView` + `AudioSourcesViewModel`, and
`AudioSourceConfig` persistence (`active` = custom list or mic+system default).

## Why

The original feature request was configurable multi-source capture — "audio of one app, audio
of another app, one mic, or multiple mics" — not just the mic+system MVP.

## Impact

- Users: opt into Custom mode to capture specific apps / multiple mics into one timestamped,
  speaker-labeled transcript. Default (mic + system) is unchanged and remains the default.
- Subsystems: capture (per-app tap + process enumeration), config persistence, settings UI,
  engine.
- Breaking: no. `AudioSourceRecord` gains an optional `kind` field (legacy rows decode as nil).
- Permissions: none new — per-app taps ride the same Audio Recording (TCC) grant as the global
  tap. macOS 14.4+ for any tap source.

## Correctness fix (found during Phase 5 review)

`VoiceInkEngine.handleMultiSourceStop` previously treated `records.first` as the primary mic.
Once sources are user-reorderable, a tap could sit at index 0 — on a cloud-model degrade this
would transcribe app/system audio and **delete the user's mic recording**. Fixed: the primary
is now selected by kind (the microphone track), never by array position, and only non-primary
WAVs are deleted.

## Gated / deferred

Soft cap of 4 sources; no drift-compensated aggregate for multi-mic (independent recorders,
with a cross-talk warning); no mid-recording re-target if a tapped app quits; Electron/browser
helper-process coverage is best-effort (bundle-ID + PID match). Per-app tap behavior when an
app routes to a non-default output device is untested. See
`docs/plans/phase5-implementation-spec.md` §9 for the full test plan.

## References

- Spec: `docs/plans/phase5-implementation-spec.md`
- Branch: `feature/multi-source-transcription`
