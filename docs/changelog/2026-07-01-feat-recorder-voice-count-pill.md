---
date: 2026-07-01
type: feat
scope: recorder
title: Recorder shows a "N voices" pill with per-source level popover in Conversation Mode
---

## What changed

During a multi-source recording, the mini recorder / notch recorder now shows a compact pill
with the number of captured sources (waveform glyph + count) instead of inlining one level bar
per source. Clicking the pill opens a popover with the live per-source level bars
(`MultiSourceLevelBarsView`); if any source goes silent, the pill itself gains an orange
warning triangle so a dead mic/tap is visible without opening the popover.

## Why

The inline per-source bars crowded the compact recorder panels, and the user wanted an
at-a-glance "how many voices are we capturing" indicator with detail on demand.

## Impact

- Users: cleaner recorder panel in Conversation Mode; click the pill to inspect each source's
  live level. Single-source recording UI unchanged.
- Subsystems: ui / recorder (`MultiSourceVoiceCountView`, `RecorderComponents`).
- Breaking: no.
- Permissions/entitlements added or changed: none.
