# Meeting mode — research findings (2026-07-02)

Condensed from the multi-agent research that led to `meeting-diarization-spec.md`. Preserved
here because the phase-2/3 decisions below depend on it.

## The hard limit (OS layer)

A Core Audio process tap on a meeting app (Teams native, Meet-in-Chrome) delivers the app's
rendered output only — all remote participants arrive **pre-mixed into one stream** (WebRTC
mixes inside the app before the HAL; `CATapDescription(stereoMixdownOfProcesses:)` is literally
a mixdown). Bot-free capture therefore yields exactly two separable streams: mic ("Me") and
combined remote ("Them"). Per-remote-speaker separation at the OS layer is impossible; the only
on-device workaround is ML diarization on the mixed track — which is what this branch ships.

## Competitive grounding (Granola, verified from its own docs)

- Granola is bot-free and local-capture like VoiceInk, but transcribes in the **cloud**
  (Deepgram/AssemblyAI; docs.granola.ai). On desktop it does **no diarization** — transcript is
  binary Me/Them ("the models don't yet support live diarization"); iOS-only diarization gives
  generic "Speaker A/B" for in-person meetings.
- Shipping open-source proof of the path this branch took: Muesli, pasrom/meeting-transcriber,
  WhisperClip — all mic+tap capture with FluidAudio/pyannote diarization on-device. Best
  practice confirmed: **dual-track** (diarize only the system track; mic is ground truth).
- Net: with this branch, VoiceInk exceeds Granola-desktop (per-remote-speaker split) while
  staying fully on-device, which Granola isn't.

## Realistic accuracy expectations

DER 20–40% on real meeting audio (compressed VoIP downlink); error roughly triples from 2→3
speakers; overlap and similar voices are the dominant failure modes. FluidAudio: ~22% DER
average, ~60× real-time on M1 ANE. Set user expectations accordingly ("beta").

## Phase 2 — sticky names via enrollment (recommended next)

FluidAudio ships `SpeakerManager` / `initializeKnownSpeakers`: 256-d voice embeddings matched
by cosine distance across meetings. User renames "Speaker 1" → "Alice" once; the embedding is
stored and re-matched in future recordings. Proven pattern (meeting-transcriber ships it).

## Phase 3 — browser-extension name feed (researched, deliberately deferred)

A Chrome extension can scrape speaker-attributed **live captions** (strong on Teams web:
semantic `data-tid` selectors; weak on Meet: positional heuristics, obfuscated markup) and feed
names to the app over an authenticated localhost WebSocket. Key design conclusions if built:

- **Names label clusters; audio decides cut points.** DOM timing lags audio by a variable
  stack (jitter buffer ~80ms+ → caption ASR sub-second → ~4s finalization debounce) plus
  browser↔`mach_absolute_time` clock drift — never cut on DOM timestamps. Bind by fuzzy TEXT
  match (our ASR vs scraped caption words), accumulate majority votes per cluster.
- Captions must be manually enabled; browser-only (native Teams/Zoom invisible — macOS AX
  scraping is the only route there, equally fragile); per-platform scrapers break on redesigns;
  ToS gray area. Hence: optional best-effort layer on top of the cluster model, never the
  segmentation source. No shipping product does this fusion today (closest: Recall's extension
  records tab audio AND scrapes captions but leaves them unfused; look-ma-no-hands #355 is the
  same design via AX, unimplemented).
