---
name: changelog
description: Use this skill to write a developer changelog entry whenever a notable change is made to VoiceInk (new feature, bug fix, refactor, breaking change, build/entitlement/config change, or notable docs update). One entry = one file in docs/changelog/, never a single big CHANGELOG.md. This is the developer history, distinct from the user-facing release notes in appcast.xml / announcements.json. Trigger after completing a change, OR when the user says "add this to the changelog", "log this change", or "changelog".
---

# Changelog Workflow (VoiceInk)

One file per change in `docs/changelog/`. Never a monolithic `CHANGELOG.md`. This is separate from the user-facing release notes (`appcast.xml`, `announcements.json`) — those are for shipped releases; this is the running developer record.

`docs/changelog/` may not exist yet — create it (`mkdir -p docs/changelog`) on first use.

## When to write an entry

Write when: a feature is added/removed/changed, a bug is fixed, a refactor changes public behavior or conventions, a build/signing/entitlement/Info.plist change lands, a SwiftData model/migration change lands, a new transcription provider or model is added, or a breaking change is introduced.

Do **not** write for: typo fixes, WIP not yet committed, pure comment changes, throwaway experiments.

## File naming

```
docs/changelog/YYYY-MM-DD-<type>-<slug>.md
```

- `<type>` — one of: `feat`, `fix`, `refactor`, `docs`, `chore`, `breaking`, `perf`, `build`
- `<slug>` — kebab-case, max 5 words

## File content template

```markdown
---
date: YYYY-MM-DD
type: feat | fix | refactor | docs | chore | breaking | perf | build
scope: audio | transcription | enhancement | models | powermode | ui | recorder | persistence | build | docs | multi
title: <one-line summary, sentence case, no trailing period>
---

## What changed

<1-3 sentences from a user/developer perspective — name the feature/module, not the files.>

## Why

<1-2 sentences. The motivation or bug symptom.>

## Impact

- Users: <what a VoiceInk user notices, or "none visible">
- Subsystems: <audio / transcription / enhancement / ui / models / powermode / build>
- Breaking: <yes + migration steps (esp. SwiftData / entitlements), or "no">
- Permissions/entitlements added or changed: <list or "none">
```

### Rules

- Write for a future reader, not the current conversation.
- Use VoiceInk terminology: **Transcription** (the SwiftData record), **PowerMode** (per-app config), **mini recorder** / **notch recorder** (the UI panels), **provider** / **model** (transcription backends), **enhancement** (the AI cleanup step), **whisper.xcframework** (the built dependency).
- No code diffs. Git history has the diff.
- Keep it under 30 lines. Link to architecture docs (`docs/architecture/*.md`) instead of duplicating.

## Step-by-step

1. Confirm the change is done.
2. Pick type and scope.
3. Generate the filename; check `docs/changelog/` for conflicts and suffix `-2`, `-3` if needed.
4. Write the file using the template.
5. Tell the user the filename in one line.

## What NOT to do

- Don't create/update a top-level `CHANGELOG.md`.
- Don't edit `appcast.xml` / `announcements.json` — those are release-publishing artifacts, not this dev log.
- Don't batch multiple unrelated changes into one entry.
- Don't delete or rewrite old entries — they are historical record.
