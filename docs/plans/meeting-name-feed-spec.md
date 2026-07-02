# Meeting name feed — implementation spec (browser extension + caption bridge)

Status: **planned, not started**. Prereq shipped: on-device diarization
(`meeting-diarization-spec.md`). Research grounding: `meeting-mode-research.md`.

## Goal

When the user records a browser meeting (Google Meet / Teams web) in Conversation Mode with
diarization on, real participant names replace "Speaker 1/2/3" **automatically** — no manual
rename. A Chrome extension reads the meeting's own speaker-attributed live captions and streams
them to VoiceInk; after transcription, VoiceInk matches caption text against its own transcript
and votes names onto the diarized voice clusters.

**Division of labor (load-bearing):** the audio pipeline decides *when* (segment boundaries from
diarization — precise, always works); the extension decides *who* (names — best-effort). The
extension is a naming layer ONLY: it never cuts audio, never becomes the transcript source, and
every failure mode degrades to today's behavior (Speaker N + manual rename).

## Non-goals (v1)

- Native Teams / Zoom desktop apps (no DOM; would need macOS AX scraping — separate spec if ever).
- Firefox/Safari ports (Safari blocks `ws://127.0.0.1` from https pages).
- Live in-meeting display of names; fusion is post-recording, in the assembler.
- Cross-meeting voice memory (that's the separate enrollment feature).

## Verified facts this design rests on

(Verified 2026-07 against live scraper repos, Chrome docs, and this repo — see
`meeting-mode-research.md` for the audio-layer research.)

1. **Content script owns the WebSocket.** MV3 service workers idle-die at 30s (WS *messages*
   reset the timer since Chrome 116, an idle socket does not). A content script lives exactly as
   long as the meeting tab — no keepalive dance. Loopback is a trustworthy origin, exempt from
   mixed-content blocking; use literal `ws://127.0.0.1:<port>` (NOT `ws://localhost` — the name
   form has historically been blocked for WS). Isolated-world content scripts are not subject to
   the page's `connect-src` CSP. Two one-line empirical checks remain (M3 exit criteria): the WS
   handshake's `Origin` header value, and the isolated-world CSP bypass for WS specifically.
2. **No entitlement work.** VoiceInk is unsandboxed and both entitlement files already carry
   `network.client` + `network.server`; a loopback `NWListener` triggers no TCC prompt and no
   Info.plist change.
3. **Same machine ⇒ same wall clock.** Browser `Date.now()` and Swift `Date()` read the same
   system clock — **no clock-sync handshake needed** (the earlier NTP-style design in the
   research doc was for monotonic-clock alignment; wall clock sidesteps it). Residual timing
   error is caption *pipeline* latency only (jitter buffer + caption ASR + UI debounce ≈ 0.5–5s),
   absorbed by text matching + generous windows.
4. **Caption DOM, current state.** Teams web: stable semantic selectors
   (`[data-tid="author"]`, `[data-tid="closed-caption-text"]`, v2 wrapper
   `[data-tid='closed-caption-v2-window-wrapper']`), but it's a **virtualized list** that
   re-mutates lines — needs stable-ID dedupe, not naive append. Meet: anchor on
   `div[role="region"][tabindex="0"]` structure (aria-label is locale-dependent, classes are
   obfuscated and rotate); Meet **retro-mutates earlier caption blocks** for corrections (read
   only the last active block), detaches the region on CC toggle (re-poll ~2s), and shows "You"
   for the local user (map to real name; also we already know "You" = our mic track anyway).
5. **Distribution.** Chrome Web Store **unlisted** works for companion-app bundling (installable
   via URL, same review as public). Load-unpacked for dev. No CWS policy against requiring a
   companion app (native messaging is an officially documented pattern). Cannot silently install
   from the Mac app.

## Architecture

```
Chrome (meeting tab)                          VoiceInk (macOS app)
┌──────────────────────────────┐             ┌─────────────────────────────────────┐
│ content script (isolated)    │   ws://     │ CaptionBridgeServer (NWListener,    │
│  • platform scraper          │  127.0.0.1  │  loopback-only, token+Origin auth)  │
│    (MeetCaptionScraper /     ├────────────►│  • session control (start/stop)     │
│     TeamsCaptionScraper)     │             │  • in-memory CaptionEvent buffer    │
│  • dedupe + finalize turns   │◄────────────┤    (only while recording)           │
│  • WS client + reconnect     │  control    └──────────────┬──────────────────────┘
├──────────────────────────────┤                            │ [CaptionEvent] at stop
│ service worker: badge/state  │             VoiceInkEngine.handleMultiSourceStop
│ popup: pairing (paste token) │                            │
└──────────────────────────────┘             MultiSourceAssembler.assemble
                                               transcribe → diarize (clusterIds)
                                               → merge (shared timeline)
                                               → CaptionNameResolver.apply  ◄── NEW
                                               → composeFlatText (real names baked in)
```

### Event schema (extension → app, JSON text frames)

```json
{"type":"hello","token":"<pairing token>","platform":"meet|teams","ver":1}
{"type":"caption","name":"Sarah Chen","text":"we could ship on Friday","tsMs":1782991234567,"turnId":"m-142"}
{"type":"bye"}
```

App → extension control frames:

```json
{"type":"hello_ack","recording":false}
{"type":"session","state":"started"|"stopped"}
{"type":"error","code":"bad_token"}
```

Rules: the extension observes captions **only while a session is started** (privacy: no
buffering outside recordings); `turnId` is the scraper's stable per-turn id (dedupe key —
re-sent turns replace, they don't append); `tsMs` is `Date.now()` at (last) mutation of that
turn. One caption frame per finalized-or-updated turn, throttled ≥300ms per turnId.

## Component 1 — `CaptionBridgeServer` (new, `Services/MultiSource/CaptionBridgeServer.swift`)

`NWListener` on `127.0.0.1`, fixed default port **47810** (fallback: +1…+9, extension probes the
range), WebSocket protocol via `NWProtocolWebSocket`. Actor.

- **Auth:** compare `hello.token` to the stored pairing token (`UserDefaults` key
  `CaptionBridgeToken`, generated on first enable, shown in settings for copy-paste into the
  extension popup). Additionally allowlist the `Origin` header
  (`https://meet.google.com`, `https://teams.microsoft.com`, `https://teams.live.com`,
  `https://teams.cloud.microsoft`, `chrome-extension://*`) — defense in depth; the token is the
  real gate (Origin is spoofable by local processes). Close on first bad frame.
- **Lifecycle:** listener runs while the feature toggle is on (so the extension can pair/show
  status any time). `beginSession()` / `endSession() -> [CaptionEvent]` bracket a recording:
  broadcast `session started/stopped`, buffer `caption` frames in memory only in between.
  A 2h meeting ≈ <1 MB of events — no file needed; **no sidecar, no cleanup surface** (the
  transient-fusion option from the seams review). Events die with the session.
- **Token/PII hygiene:** never log caption text or names (`privacy: .public` only for counts);
  never log the token.

## Component 2 — engine lifecycle wiring (`Whisper/VoiceInkEngine.swift`)

- `tryStartMultiSource` (after the abort-guard, where `multiSourceCoordinator` is assigned,
  ~:323): if bridge enabled → `bridge.beginSession()`, and **store the session wall-clock t0**
  (`Date()` captured at the same moment as `timeline.anchorNow()`). The engine must also retain
  the `sessionID`/t0 on a property — today `sessionID` is a local (verified :305).
- `handleMultiSourceStop`: happy path → `let captions = await bridge.endSession()` after
  `coordinator.stop()`, pass `(captions, wallClockT0)` into `assemble`. Cancel branch,
  empty-records branch, and the single-source degrade branch each call `endSession()` and
  **discard** events (per-branch coverage verified at :361-367, :370-380, :417-433).

## Component 3 — `CaptionNameResolver` (new, pure, `Services/MultiSource/CaptionNameResolver.swift`)

Runs in `MultiSourceAssembler.assemble` **between `TranscriptMerger.merge` and
`composeFlatText`** (verified seam — merged segments are on the shared timeline with cleaned
text and `clusterId`s intact; renaming before compose bakes names into `Transcription.text` for
free). Skipped when there are no caption events or no diarized clusters.

Algorithm (all thresholds named constants, unit-tested):

1. **Timeline mapping:** caption `tsMs` → seconds-from-record-start via `wallClockT0`. Window
   each caption event to `[t − 8s, t + 2s]` (captions lag speech; never lead it by much).
2. **Candidate matching:** for each caption event, take transcript segments overlapping the
   window; score by normalized token overlap (lowercase, strip punctuation/diacritics;
   contiguous-bigram bonus). Meet paraphrases aggressively — accept ≥0.5 similarity; discard
   below (the caption may cover speech the ASR missed, or vice versa).
3. **Voting:** each match = one `(clusterId → name)` vote, weighted by similarity × caption
   length (longer utterances are more reliable). "You" votes and votes matching mic-track
   segments (no clusterId) are dropped — the mic is already "Me".
4. **Assignment:** per cluster, assign the majority name iff ≥ 3 votes AND ≥ 70% of that
   cluster's vote mass; else keep "Speaker N". One name can win multiple clusters (people
   rejoin/two devices) — allowed, but flag in log. Apply via a new
   `SegmentSpeakerLabeler.renameCluster(segments:clusterId:to:)` (keyed on `clusterId`, not
   display label — the existing `rename` stays for the manual UI).
5. **Provenance:** resolver-assigned names are still just `speaker` strings; `clusterId` is
   untouched, so manual rename keeps working on top.

Degrade rules: resolver failure/no votes/ambiguity → keep "Speaker N". It must never rename to
an empty/duplicate-role string (reuse the uniqueness rules from invariant 5).

## Component 4 — Chrome extension (new top-level `extension/` dir, plain JS, no build step)

Outside `VoiceInk/` so Xcode's synchronized groups ignore it.

```
extension/
  manifest.json          MV3; content_scripts on the 4 meeting domains; "storage" permission only
  shared/bridge.js       WS client: probe ports 47810-47819, hello/token, reconnect w/ backoff,
                         session-state gate (observe only while recording)
  content/meet.js        MeetCaptionScraper (structure-anchored per §Verified-4; 2s region
                         re-poll; last-active-block only; correction-aware turnId replace)
  content/teams.js       TeamsCaptionScraper (data-tid selectors; virtualized-list dedupe by
                         stable turn identity; wrapper fallbacks)
  worker.js              badge state only (paired / in-meeting / recording)
  popup/                 pairing UI: paste token, connection status, "captions on?" reminder
```

Scraper contract (both platforms): emit `{name, text, tsMs, turnId}`; replace-on-update by
`turnId`; finalize a turn when unchanged for 3s or a new speaker's turn starts. The scrapers are
the ONLY per-platform code — everything else is shared.

## Component 5 — Settings UI (`Views/Settings/AudioInputSettingsView.swift`)

New card inside the existing `if twoSourceEnabled` block, copying the diarization-toggle
template exactly (toggle + caption; `.onChange` async setup with revert-on-failure + alert —
pattern verified at :73-103):

- Toggle **"Name speakers from your meeting page (beta)"** (`CaptionBridgeEnabled`) — requires
  diarization toggle on (names need clusters); starting the listener on enable, alert+revert if
  the port bind fails.
- Status row: extension paired/connected (server pushes state), last session's caption count.
- Pairing token with copy button + "Install the extension" link (CWS unlisted URL).
- Caption `Label` rows: "Works with Google Meet and Teams in Chrome — turn on captions in the
  meeting", "Names never leave your Mac".

## Security & privacy (map to security-checklist)

- **Egress: none.** Captions flow browser → localhost → memory → local SwiftData. Nothing
  outbound. The extension talks only to 127.0.0.1 (CWS review point: single purpose, minimal
  permissions, no remote endpoints).
- **Inbound surface:** loopback listener, token-gated, Origin-allowlisted, feature-toggled off
  by default, session-gated buffering. Malicious local process without the token gets
  `bad_token` + close; worst case with a stolen token is *injecting fake names* into a local
  transcript — no read-back of transcript data is ever served (server is write-only from the
  client's perspective).
- **Caption text is other people's words** — same sensitivity class as the transcript itself:
  in-memory only, never logged, never persisted beyond the fused names in `segmentsJSON`.
- **ToS note:** reading the user's own visible captions in their own session is the least-exposed
  variant of meeting scraping (no bot, no hidden automation), but Meet/Teams DOM has no API
  contract — document as beta, expect breakage, fail silent-but-visible (status row).

## Invariants preserved (conversation-mode skill)

- Pipeline never blocks on the bridge: `endSession()` returns whatever arrived; no waiting, no
  network in `runMultiSource` (trap 6 analog).
- Flat text stays canonical: resolver runs before `composeFlatText`; manual rename path
  unchanged (trap 5).
- Per-source degrade: no captions / no extension / captions off ⇒ output byte-identical to
  the current diarization behavior (invariant 3 spirit).
- Mic track never renamed by the resolver (invariant 1 spirit: mic is ground truth).

## Testing

- **Unit (Swift Testing, pure):** `CaptionNameResolverTests` — vote thresholds, paraphrased
  captions (Meet-style lossy text fixtures), lag windows, "You" exclusion, ambiguity → Speaker N,
  cluster-keyed rename. Fixture pairs of (ASR segments, caption events) hand-built + one set
  generated from a real meeting once M5 runs.
- **Integration:** test target opens a real `URLSessionWebSocketTask` to `CaptionBridgeServer`
  (loopback, ephemeral port): auth accept/reject, session gating, buffer contents, concurrent
  connect.
- **Extension:** fixture HTML snapshots of Meet/Teams caption DOM (from the reference repos) +
  a tiny harness page driving mutations; assert emitted event streams (dedupe, corrections,
  virtualized-list churn).
- **Manual (signed build):** real Meet + Teams calls; the two flagged empirical checks (WS
  `Origin` value, isolated-world CSP bypass) recorded in this doc when done.

## Milestones

| # | Deliverable | Size | Exit criteria |
|---|------------|------|---------------|
| M1 | `CaptionBridgeServer` + settings card + engine wiring | M | integration tests green; toggle → listener up; fake client streams into a recording |
| M2 | `CaptionNameResolver` + assembler slot + `renameCluster` | M | unit suite green incl. lossy-caption fixtures; end-to-end with fake events renames clusters |
| M3 | Extension core + **Teams** scraper (stable selectors first) | M | live Teams web call → names in transcript; empirical WS checks recorded |
| M4 | **Meet** scraper (fragile DOM, correction/dedupe handling) | M–L | live Meet call → names; survives CC toggle + language change |
| M5 | Polish + CWS unlisted submission + docs/changelog/skill sync | S–M | install-from-URL flow works end-to-end for a fresh user |

Teams before Meet deliberately: stable selectors validate the whole pipeline with minimal DOM
fighting; Meet's volatility then lands on a proven base. Flip M3/M4 if real usage is Meet-heavy.

## Open questions (decide before/at implementation)

1. **Meet-first instead?** (Which platform do you actually meet in most?)
2. Popup pairing via paste-token is the simple v1 — acceptable, or invest in an auto-pairing
   flow (app opens `chrome-extension://…/pair.html?token=…`) later?
3. CWS developer account available for the unlisted listing, or keep load-unpacked for v1?
4. Native-messaging fallback (no port, no token, SW-kept-alive) if the WS empirical checks
   surprise us — acceptable plan-B complexity?

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Meet DOM breaks after a Google release | High, recurring | structure-anchored selectors; scraper isolated per platform; status row surfaces "0 captions"; degrade = Speaker N |
| Captions left off by user | High | popup + settings reminder; degrade = Speaker N |
| Wrong-name assignment (bad match) | Medium | vote thresholds; manual rename always wins afterwards; log vote stats |
| CWS review friction (companion app) | Low–Medium | native messaging is an official pattern; unlisted visibility; load-unpacked interim |
| Port squatting / token leak | Low | token gate; worst case = fake names locally; regenerate-token button |
