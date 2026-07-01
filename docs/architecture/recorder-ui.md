# Recorder UI

The mini/notch recorder panels shown while recording (`VoiceInk/Views/Recorder/*`), presented by `Whisper/RecorderUIManager.swift`.

## Status display

- `RecorderComponents.swift` — shared panel components. `RecorderStatusDisplay` picks what to render per state: processing indicator, single-source `AudioVisualizer` waveform, or — when recording with a non-empty `multiSourceLevels` (Conversation Mode) — the compact `MultiSourceVoiceCountView` pill.
- `MultiSourceVoiceCountView.swift` — the "N voices" pill for multi-source recording. Collapsed: waveform glyph + source count, with an orange warning badge if any source `isSilent` (dead mic/tap visible at a glance). Tapping opens a popover embedding `MultiSourceLevelBarsView` with one live level bar per source.
- `MultiSourceLevelBarsView.swift` — per-source tinted level bars + "no audio" hint; now shown inside the pill's popover rather than inline in the panel.
- `RecorderStateProvider.swift` — publishes recorder state to the views, including `MultiSourceLevel` (per-source level + silence flag).
