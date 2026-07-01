---
name: security-checklist
description: Use this skill BEFORE shipping any VoiceInk change that touches audio/transcript data, sends anything to a network provider (cloud/streaming STT or LLM enhancement), reads screen/clipboard context, pastes into other apps, handles API keys, or changes entitlements/permissions. The standing security & privacy checklist for VoiceInk. This is the project-specific companion to the generic /security-review command.
---

# VoiceInk Security & Privacy Checklist

VoiceInk is a **privacy-first, local-by-default** voice app that is **not sandboxed** and holds powerful entitlements (audio input, screen capture, Apple Events automation) plus runtime **Accessibility (AX)** access (a TCC permission, not a static entitlement). That combination means a careless change can quietly exfiltrate a user's speech, screen, or clipboard. Run through these checks before any non-trivial change.

## Check 1 — Local-by-default; network egress is opt-in and explicit

The core promise is that local models (whisper.cpp / Parakeet / Apple Speech) never send audio off-device. Before adding or changing a transcription path:

- Confirm **local providers never hit the network.** Only `.groq` / `.elevenLabs` / `.deepgram` / `.mistral` / `.gemini` / `.soniox` / `.custom` (via `Services/CloudTranscription/*` and `Services/StreamingTranscription/*`) send **audio** to a third party. Never route local-model audio through a cloud/streaming service by accident (check `TranscriptionServiceRegistry.service(for:)` / `createSession`).
- **AI enhancement** (`Services/AIEnhancement/*`) sends the **transcript text** — and, when context is enabled, **clipboard + OCR'd screen content** (`ScreenCaptureService`) — to an LLM. Any change that widens what context is captured or sent must be gated on the existing user setting, not on by default.
- New outbound calls use `URLSession` over HTTPS. Never disable TLS validation. Never log full request/response bodies containing audio, transcripts, or keys.

## Check 2 — Secrets: API keys stay in the Keychain

- All provider API keys go through `KeychainService` / `APIKeyManager` — never `UserDefaults`, never a plist, never a constant in source, never a log line. `Obfuscator.swift` is not a secret store; don't treat obfuscation as encryption.
- Grep your diff for hardcoded tokens before committing: no `sk-…`, bearer strings, or embedded credentials.
- Don't print keys in `Logger` calls (watch `privacy: .public` — never mark a key or transcript `.public`).

## Check 3 — Accessibility / paste injection (CursorPaster)

- `CursorPaster` / `ClipboardManager` inject text into the frontmost app via Accessibility (AX) + synthesized paste. Only ever paste the **user's own transcription result**. Never auto-paste content derived from untrusted input (see Check 5) without the user initiating it.
- If you touch clipboard save/restore, ensure the user's prior clipboard is restored and not leaked into a transcript, log, or network call.

## Check 4 — Recordings & transcripts at rest

- Recordings are written unencrypted to `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings/<UUID>.wav`. Transcripts persist **locally** in SwiftData — the `Transcription` store is configured `cloudKitDatabase: .none` (`VoiceInk.swift`), so transcripts stay on-device. It is the **dictionary** store (`VocabularyWord` / `WordReplacement`) that is CloudKit-synced (`.private(...)`, non-`LOCAL_BUILD` builds only). Respect the existing retention / auto-cleanup path (`Views/Settings/AudioCleanup*`) — don't create WAVs that escape cleanup. If you ever move `Transcription` (or a new PII field) into a CloudKit-backed store, treat that as a privacy change requiring explicit review.
- Temp/derived audio (e.g. per-source captures for a multi-source feature) must be cleaned up on cancel and on error, not just on the happy path.

## Check 5 — Untrusted input to LLMs (prompt injection)

- Screen OCR, clipboard contents, and the transcript itself are **attacker-influenceable** (a malicious on-screen document can contain "ignore your instructions…"). When any of these is placed into an enhancement prompt, treat it as **data, not instructions** — keep it clearly delimited from the system/user instructions, mirroring how `AIEnhancementService` already frames context.
- A change that lets model output drive an action (paste, run, network) is a red flag — keep enhancement output inert text that the user still controls.

## Check 6 — Entitlements & permissions (least privilege)

- Any new capability must be added to **both** `VoiceInk/VoiceInk.entitlements` and `VoiceInk/VoiceInk.local.entitlements` (the `make local` build uses the latter) — and justified. Don't add an entitlement "just in case".
- New TCC-gated capabilities (e.g. system-audio capture, a second microphone, screen recording for audio taps) need a matching usage-description in `Info.plist` and a graceful denied-permission path in the onboarding/permissions UI (`Views/PermissionsView.swift`, `Views/Onboarding/OnboardingPermissionsView.swift`) — never crash or silently no-op on denial.
- The app is intentionally **not sandboxed**; do not assume sandbox protections exist. Conversely, don't broaden Apple Events / automation scope beyond what a feature needs.

## After the review

- If the change crosses a trust boundary or touches auth/secrets/egress, note the residual risk in the PR/changelog entry.
- For a deeper generic pass, the built-in `/security-review` command still applies — this checklist is the VoiceInk-specific layer on top of it.
