---
date: 2026-07-02
type: feat
scope: ui
title: Menu bar shows active mic and adds Conversation Mode quick toggle
---

## What changed

The menu bar (quick drawer) Audio Input submenu now shows the currently active microphone in
its label ("Audio Input: MacBook Pro Microphone"), mirroring the "Transcription Model: X"
pattern, and gained an "Audio Input Settings" shortcut that opens the settings page directly.
A new "Conversation Mode (Mic + System)" toggle sits below it, so multi-source capture can be
switched on/off without opening the app window.

## Why

The device picker existed in the menu but was invisible at a glance (static "Audio Input"
label), and toggling Conversation Mode required navigating to Settings → Audio Input every
time — a frequent switch while alternating between dictation and conversation capture.

## Impact

- Users: see and switch the active mic from the menu bar; one-click Conversation Mode toggle.
- Subsystems: ui (menu bar only — `MenuBarView`); no engine/settings behavior change.
- Breaking: no.
- Permissions/entitlements added or changed: none.
