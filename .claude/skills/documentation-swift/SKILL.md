---
name: documentation-swift
description: Use this skill whenever you create or modify a Swift file under VoiceInk/. Ensures every file has a header comment describing its purpose and every public/exported declaration (type, protocol, function, property) has a doc comment. After updating the source, delegates the architecture-doc update to the `docs-updater` sub-agent. Trigger on any change to VoiceInk/**/*.swift.
---

# Swift Documentation Skill (VoiceInk)

## Rules

1. **File header** — every `.swift` file opens with a `//` header (2–3 lines) naming what the file is and the subsystem it serves, e.g. `// CoreAudioRecorder — AUHAL-based single-device capture; converts to 16kHz mono Int16 WAV and streams PCM via onAudioChunk.` Match the neighbouring files' style (many existing files use a `// MARK:` structure rather than a header — keep that, and add a one-line purpose at the top).
2. **Doc comments on public API** — every non-private `struct`/`class`/`enum`/`protocol`/`func`/computed property gets a `///` doc comment: a one-line summary, plus `- Parameter` / `- Returns` / `- Throws` when non-obvious. The codebase already does this in places (e.g. `TranscriptionService`, `TranscriptionPipeline.run`) — follow that.
3. **Private helpers** — a one-line `///` is enough; only expand when the logic is non-obvious.
4. **No comments for obvious code.** Add an inline comment only when the WHY is non-obvious: a real-time-thread constraint, a subtle invariant, a workaround for a specific bug (e.g. the "no malloc in the audio callback" rule in `CoreAudioRecorder`).
5. **Concurrency annotations are documentation too** — when adding `@MainActor`, `Sendable`, or moving work onto a dispatch queue, keep the reason legible.

## After editing source files

Spawn the `docs-updater` agent to sync the architecture docs:

```
Agent({
  description: "Update architecture docs",
  subagent_type: "docs-updater",
  prompt: "Files changed this turn:\n- <path>\n\nUpdate the corresponding docs/architecture/*.md as needed. Run git diff yourself."
})
```

If `subagent_type: "docs-updater"` isn't registered in the current session yet (newly added agents load on the next session), inline the same task into a `general-purpose` agent instead, pointing it at `.claude/agents/docs-updater.md`.

## Notes

- `docs/architecture/` does **not exist yet** — the `docs-updater` agent will create per-subsystem files on first use. Keep them lean; they index the code, they don't duplicate it.
- Separately, notable changes still get a **changelog** entry (see the `changelog` skill) — that's user-facing history, distinct from the architecture docs.
