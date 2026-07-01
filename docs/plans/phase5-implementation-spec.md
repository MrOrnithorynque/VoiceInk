I have verified the contested engine code. The critique is accurate: `records.first` at line 352/366/373 and the degrade-path at 394-406 assume index 0 is the primary mic, and the `for extra in records.dropFirst()` deletes all other WAVs. This confirms the engine must change. I now have everything needed to write the final spec.

# VoiceInk Phase 5 — Configurable N Audio Sources: Final Implementation Spec

Status: buildable. Supersedes the "engine never changes" framing in the v1 `AudioSourceConfig`/`CaptureSourceFactory` header comments — those comments are now factually wrong for the degrade path and must be updated (see §1, §6, §9-BUG1).

---

## 1. Scope, and what is cut / gated

### In scope (Phase 5a/5b/5c)
- **5a — engine correctness prerequisites (blocking, ship first):** replace the index-0 "primary = `records.first`" assumption in `VoiceInkEngine.handleMultiSourceStop` with an explicit primary chosen by *kind/role*, so user-reorderable sources cannot cause silent mic-audio loss. Add a real all-sources-invalid → mic-only fallback.
- **5b — per-app tap + process enumeration:** implement `CaptureSourceFactory.app` via `CATapDescription(stereoMixdownOfProcesses:)`; add `AudioProcessEnumerator`; hoist shared Core Audio helpers.
- **5c — settings UX:** the Custom-sources composition surface, gated behind the existing `TwoSourceTranscriptionEnabled` master toggle and a new Default/Custom mode picker.

### Cut / gated
| Item | Decision |
|---|---|
| Multi-mic **drift-compensated aggregate device** (single IOProc + channel demux) | **CUT.** Keep one independent `MicCaptureSource`/`CoreAudioRecorder` per mic. Reserved for a hypothetical future beamforming feature only. |
| `CATapDescription(monoMixdownOfProcesses:)` and `(processes:deviceUID:stream:)` | **CUT.** Use `stereoMixdownOfProcesses` only; `ExtAudioFile` already downmixes to 16k/mono/Int16. |
| **Reorder moving a non-mic into slot 0** | **GATED.** Reorder is allowed, but a microphone is always pinned as the primary regardless of array order (§6, §9-BUG1). If 5a slips, cut the reorder affordance entirely and pin mic to index 0. |
| **Unbounded N sources** | **GATED.** Soft-cap at **4** in the picker; warn past 3. N× serial transcription latency requires per-source progress UI (§7). |
| **Two mics on the same physical device** (incl. `nil`-default vs explicit-UID collision) | **BLOCKED** at add-time after resolving `nil`→concrete default UID (§5, §9-BUG3). |
| **Mid-recording re-target** when a tapped app quits/relaunches | **CUT.** Documented limitation; post-record "captured nothing" hint instead. No `ProcessObjectList` change-listener rebuild (real-time re-plumbing hazard). |
| macOS < 14.4 | Tap kinds (`.systemGlobal`, `.app`) shown disabled; `.app` **must** be wrapped in `#available(macOS 14.4, *)` in the factory — the per-app initializers are *not* availability-annotated at the Swift call site and will compile below 14.2, failing only at `AudioHardwareCreateProcessTap` (§4, §8). |
| New TCC prompt / new entitlement | **NONE.** Per-app tap rides the same audio-capture permission as the shipped global tap (verified: sandbox off, `device.audio-input` granted, `NSAudioCaptureUsageDescription` present). |

---

## 2. New / changed files by layer

### Layer: Services/MultiSource/ (capture core)

| File | Change |
|---|---|
| `Services/MultiSource/CoreAudioUtils.swift` **(new)** | Hoist `translatePIDToProcessObject(_:)` out of `SystemAudioTapRecorder` into a shared `enum CoreAudioUtils`; add `resolveMicDeviceID(uid:deviceManager:)` (UID→AudioDeviceID via `kAudioHardwarePropertyTranslateUIDToDevice`, checking `!= kAudioObjectUnknown`). Single implementation for both tap-creation and mic paths. |
| `Services/MultiSource/AudioProcessEnumerator.swift` **(new)** | `kAudioHardwarePropertyProcessObjectList` → `[AudioProcessInfo]` (objectID, pid, bundleID?, name, icon, isRunningOutput); filters out VoiceInk's own PID; joins with `NSRunningApplication`. Provides `resolveProcessObjects(forBundleID:)` for record-time re-resolution (returns `[AudioObjectID]`, may be empty). |
| `Services/MultiSource/AppAudioTapRecorder.swift` **(new)** | Per-app `CaptureSource`; the *only* functional difference from `SystemAudioTapRecorder` is `CATapDescription(stereoMixdownOfProcesses: targetProcesses)`. Calls the shared tap-chain builder. Resolves processes at start, not construction. |
| `Services/MultiSource/TapChainBuilder.swift` **(new)** | Extract steps 3–7 of `SystemAudioTapRecorder.setUpTapChain` (read tap format → resolve output-device UID as clock anchor → build private aggregate → `ExtAudioFile` at 16k/mono/Int16 → start IOProc) into `build(tapID:role:outputURL:) -> (aggregateID, ioProcID, writer)`. Both tap recorders call it; ~80 lines de-duplicated. |
| `Services/MultiSource/SystemAudioTapRecorder.swift` **(edit)** | Remove the hoisted `translatePIDToProcessObject`; call `TapChainBuilder.build` for steps 3–7; keep the exclude-list `CATapDescription` construction. Hoist `TapError` to a shared type both recorders use. |
| `Services/MultiSource/CaptureSourceFactory.swift` **(edit)** | Implement `.app` case: `guard #available(macOS 14.4, *)`, resolve processes via `AudioProcessEnumerator.resolveProcessObjects(forBundleID:)`, return `AppAudioTapRecorder`. Remove `perAppNotYetSupported`. Empty-resolution → throw so coordinator degrades (drops that source). |
| `Services/MultiSource/AudioSourceConfig.swift` **(edit)** | Add `var isMicrophone: Bool`. Add a **primary-selection helper** `static func primaryIndex(in records:)`/role tagging so the engine can pick primary by kind, not array index. Update the "engine never changes" header comment to note the degrade path now selects primary by kind. No storage-shape change (§6). |
| `Services/MultiSource/MultiSourceCaptureCoordinator.swift` **(edit, minimal)** | No structural change. Confirm `noSourcesStarted` still thrown only when *every* source fails to **start** (start-failure path already degrades correctly in `tryStartMultiSource`). The zero-*frames* case is handled in the engine (§9). |

### Layer: Whisper/ (engine — Phase 5a, blocking)

| File | Change |
|---|---|
| `Whisper/VoiceInkEngine.swift` **(edit, lines 342–408)** | Replace three `records.first` uses and the `records.dropFirst()` delete loop. Choose `primary` = first record whose source is a `.microphone` (fall back to `records.first` only if no mic present). In the degrade branch, transcribe the **mic** record (not `records[0]`) and only delete non-primary WAVs. Add: if `records.isEmpty`, degrade to **mic-only single-source** fallback (matches the §3/§7 UX promise) instead of silently producing nothing. |

### Layer: Services/MultiSource/ (transcription assembly — role integrity)

| File | Change |
|---|---|
| `Services/MultiSource/TranscriptMerger.swift` **(edit)** | No behavior change required *if* roles are enforced unique upstream (§9-BUG2). Add a defensive comment: `composeFlatText` groups by `speaker`/role string, so duplicate roles collapse — uniqueness is a VM invariant. |
| `Services/MultiSource/MultiSourceAssembler.swift` **(edit)** | Emit a per-source progress signal (index/total + role) before each serial `transcribeWithSegments` call, consumed by the recorder UI (§7). |

### Layer: Views/Settings/ (Phase 5c UX)

| File | Change |
|---|---|
| `Views/Settings/AudioInputSettingsView.swift` **(edit)** | Replace `systemAudioSection` body: keep the `TwoSourceTranscriptionEnabled` master toggle; add `@AppStorage("ConversationSourcesMode")` + a 2-card `ConversationModePicker` (Default \| Custom). Show `AudioSourcesSettingsView()` only when mode == `.custom`. |
| `Views/Settings/AudioSourcesSettingsView.swift` **(new)** | Hosts `AudioSourcesSettingsView`, `AudioSourceCard`, `AddSourceMenu`, `AppAudioPickerSheet`, `AppRow`, `AudioSourcesViewModel`. Composition surface; persists via `AudioSourceConfig.saveConfigs`. |

### Layer: Services/ (no change)
| File | Change |
|---|---|
| `Services/AudioDeviceManager.swift` | **No change.** Reused for `availableDevices` (uid/name), device-change notifications, and default-input UID resolution. |

---

## 3. Per-app tap approach

**Primitive (confirmed against the on-disk `CoreAudio.swiftmodule` overlay + `CATapDescription.h`):**

```swift
let tapDescription = CATapDescription(stereoMixdownOfProcesses: targetProcesses) // [AudioObjectID]
tapDescription.name = "VoiceInk App Capture (\(bundleID))"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted
tapDescription.uuid = UUID()
// DO NOT set .isExclusive — it is implicitly false for this include-list initializer.
var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)   // API_AVAILABLE(macos(14.2))
```

- `stereoMixdownOfProcesses` is the **include-list** counterpart of the shipped exclude-list `stereoGlobalTapButExcludeProcesses`. Element type is `[AudioObjectID]` (`UInt32` typedef), **not** `[NSNumber]` — the ObjC `NS_REFINED_FOR_SWIFT` header is re-exposed typed for Swift. No boxing.
- The array element type means multiple process objects for one app are passed together and mixed. **Chromium/Electron caveat (§8):** browser tabs / Slack huddles route audio through renderer helper processes whose bundle ID differs from (or is absent on) the main bundle. Resolution must therefore include the selected process's **PID and its child/helper PIDs**, not only an exact bundle-ID string match — see §4.

**Process resolution (at record-start, never at config-save):**
`CaptureSourceFactory.app` calls `AudioProcessEnumerator.resolveProcessObjects(forBundleID:)`. If that returns empty (app not running / not yet audio-active), the factory throws → coordinator degrades → that source is dropped (normal, not fatal). Process `AudioObjectID`s are ephemeral (invalid across relaunch), exactly like `AudioDeviceID`s across reconnect, so resolution is always fresh.

**Anchor-device note (§8 latent bug):** `TapChainBuilder` anchors the private aggregate on `kAudioHardwarePropertyDefaultSystemOutputDevice`. Correct for the global tap. For a per-app tap where the app plays to a *non-default* output (e.g. AirPods while system default is speakers), the tap still captures the process stream but is clocked against a device the app isn't using — **untested**. Phase 5b test plan (§9) must exercise the routed-to-different-device case; if it drops frames, switch the per-app anchor to the app's actual output device.

---

## 4. Process enumeration approach

New `AudioProcessEnumerator` (mirrors Apple's AudioCap `AudioProcessController`):

1. **List:** two-call `AudioObjectGetPropertyDataSize`/`GetPropertyData` on `kAudioObjectSystemObject` for `kAudioHardwarePropertyProcessObjectList` (`'prs#'`) → `[AudioObjectID]`.
2. **Per object:** `kAudioProcessPropertyPID` (`'ppid'`) → pid; `kAudioProcessPropertyBundleID` (`'pbid'`) → CFString (empty/unreadable ⇒ treat as no bundle ID, fall back to `proc_name`); `kAudioProcessPropertyIsRunningOutput` (`'piro'`) → sort audible apps to top.
3. **Display join:** `[pid_t: NSRunningApplication]` from `NSWorkspace.shared.runningApplications` for `localizedName`/`icon`/`bundleURL`; headless helpers (no match) fall back to `proc_name` + generic executable icon.
4. **Self-filter:** drop `ProcessInfo.processInfo.processIdentifier`.
5. **Live refresh (picker only):** observe `NSWorkspace.shared.publisher(for: \.runningApplications, options: [.initial, .new])` so the sheet doesn't go stale.

**Record-time re-resolution** (`resolveProcessObjects(forBundleID:)`): find `NSRunningApplication` matching `bundleIdentifier`, take its PID **plus** the PIDs of any process-list entries whose parent is that PID (helper coverage), translate each via `CoreAudioUtils.translatePIDToProcessObject` (`'id2p'`, checking `!= kAudioObjectUnknown` — a miss returns `noErr` + `kAudioObjectUnknown`, not an error). Return the deduped `[AudioObjectID]`.

There is **no** bundleID→ProcessObject HAL translation — bundleID is the only stable persisted key; PID/objectID are always re-derived.

---

## 5. Mic-by-UID resolution + multi-mic drift decision

**UID resolution (`CoreAudioUtils.resolveMicDeviceID`):**
- Fast path: `kAudioHardwarePropertyTranslateUIDToDevice` (`'uidd'`), passing the UID `CFString` as **qualifier**. **Must check `status == noErr` AND `deviceID != kAudioObjectUnknown`** — a stale/disconnected UID resolves to `noErr` + `0`, not an error.
- Fallback: `AudioDeviceManager.shared.availableDevices.first { $0.uid == uid }`.
- `.microphone(deviceUID: nil)` → resolve the concrete current default input UID *first* (used both to record and for the dedup check in §9-BUG3).
- This is independent of `AudioDeviceManager`'s single "selected device" mode — a second explicitly-chosen mic must not be coupled to that state. `MicCaptureSource(role:deviceUID:)` resolves its own UID at `start()`.

**Multi-mic clock drift — DECISION: independent recorders, no aggregate.**
VoiceInk merges at the **segment level** (`TranscriptMerger.merge` shifts each source by its own `t0Offset` and sorts; there is no continuous shared sample timeline). Tens of ms of inter-mic clock drift over a dictation is invisible in the merged transcript. Therefore: **one independent `MicCaptureSource`/`CoreAudioRecorder` per mic** (today's mic+tap pattern, just N mics). Do **not** wrap mics in a drift-compensated aggregate (that needs a single IOProc + manual channel demux + mid-record device-removal handling — real cost, no benefit here).

**Correction to the earlier caveat framing:** the *headline* multi-mic risk is **acoustic cross-talk / duplicated speech** (two mics in one room both hear both speakers → the same utterance transcribed twice under two labels), **not** clock drift. The settings warning copy (§7-4a) must lead with cross-talk; drift is a secondary line. Same-device duplication is blocked outright (§9-BUG3). Accepted limitation, documented in code: "multi-mic timestamps may drift tens of ms on very long recordings."

---

## 6. Config persistence shape + configured-vs-default selection

**Storage shape — unchanged from v1.** `[AudioSourceConfig]` JSON-encoded under `UserDefaults["MultiSourceConfigs"]`, exactly the `PrioritizedDevice` pattern in `AudioDeviceManager`. `AudioSourceKind` cases: `.microphone(deviceUID: String?)`, `.systemGlobal`, `.app(bundleID: String)`. Each config carries `id: UUID` and `role: String`. **Array order is meaningful** = merge/label order.

**Engine selection contract — `AudioSourceConfig.active`:** custom configs when set **and non-empty** → custom; else `mvpDefault` (`[mic→"Me", systemGlobal→"Them"]`). Switching the mode picker to **Default** calls `clearConfigs()`; writing any custom list calls `saveConfigs`. `tryStartMultiSource` still reads `active` and calls `CaptureSourceFactory.makeSources` — this seam is unchanged.

**What DID change (the seam is not free):** `handleMultiSourceStop` must no longer treat `records[0]` as the primary mic. Add:
- `AudioSourceConfig.isMicrophone`.
- The engine tags each `AudioSourceRecord`/coordinator source with its kind (or the engine correlates `records` back to the source's `role`/kind), then selects `primary = firstMicRecord ?? records.first`. The saved `audioFileURL`, `duration`, and the **degrade-path transcription target** all use this mic-primary, and only **non-primary** WAVs are deleted. This is Phase 5a and blocks reorder shipping (§9-BUG1).

---

## 7. Settings UX

**Location & coexistence:** inside the existing Conversation-Mode section, gated by the `TwoSourceTranscriptionEnabled` master toggle.

```
systemAudioSection (VStack)
├─ Text("System Audio (Conversation Mode)")
├─ Toggle($twoSourceEnabled)                         // master gate (unchanged)
├─ if twoSourceEnabled:
│   ├─ ConversationModePicker                        // 2 cards: Default (Mic+System) | Custom (Advanced)
│   └─ if mode == .custom: AudioSourcesSettingsView()
└─ requirement Labels (cpu / local-model / lock.shield)
```

- **Default** → `clearConfigs()`; no list; ~95% of users. **Custom** → composition surface.

**`AudioSourcesViewModel` (`@MainActor ObservableObject`)** — thin wrapper over `saveConfigs`/`loadConfigs`, mirroring `AudioDeviceManager.prioritizedDevices`:
- `add(kind:role:)`, `remove(id:)`, `move(from:to:)`, `setRole(id:_:)`, `setDevice(id:uid:)`; `persist()` after every mutation.
- **Invariants enforced here:** unique non-empty roles (§9-BUG2); no same-physical-device duplicate mic incl. `nil`↔default-UID (§9-BUG3); **soft-cap 4 sources** (disable Add past 4; warn past 3); a microphone remains present/primary.

**`AudioSourceCard`** (sibling of `DevicePriorityCard`): leading kind icon (`mic.fill` / `speaker.wave.3.fill` / app icon via `NSWorkspace.icon(forFile:)` / `waveform`); inline-editable role `TextField(.plain)` with uniqueness validation; subtitle (device name / app name / "All system output"); for `.microphone` a device `Menu` bound to `availableDevices` storing **UID** ("Default input" = `nil`); trailing availability capsule + drag handle + remove button (disabled when only one source or when removing the last mic).

**`AddSourceMenu`** (native `Menu`): "Microphone…" (submenu of `availableDevices`), "App audio…" (opens sheet), "System output (all apps)" (adds `.systemGlobal`, disabled if one exists). Add disabled at cap.

**`AppAudioPickerSheet`:** searchable list from `AudioProcessEnumerator` (audio-known processes, currently-playing sorted to top), tap → `.app(bundleID:)`. Note: "Only apps currently producing audio can be tapped; an app added here is captured whenever it plays."

**Availability / degraded states (live, via device-change + process publishers):**
- Mic UID not in `availableDevices` → "Unavailable" capsule; copy "Will fall back to default input."
- App with no live audio process → **"Not playing"** (orange). Never auto-removed (config keys on bundleID; re-attaches).
- `.systemGlobal` with no output device → "No output device."
- Empty list → `emptyDevicesState` hero + "Reset to Mic + System" (restores `mvpDefault`).
- Permission (audio-capture TCC not granted) → inline `lock.shield` warning + "Grant Audio Recording permission" (soft; coordinator degrades). On < 14.4 tap kinds disabled with `systemAudioUnavailable` copy.

**N× latency progress (§ required):** during assembly, show "Transcribing source X of N — {role}…" in the recorder/post-record UI, driven by `MultiSourceAssembler`'s new per-source signal.

**4a — multi-mic caveat (rewritten):** when ≥2 `.microphone` sources on distinct devices, persistent `exclamationmark.triangle` `.orange` note:
> "Recording two separate microphones in the same room can capture the same speech twice under different labels (cross-talk). For a clean split, use one mic plus system or app audio. On long sessions their clocks may also drift slightly."

Recommend "one mic + system/app" as the good preset.

**4b — per-app that stopped playing:** "Not playing" capsule in settings; at record time a silent app's tap yields 0 frames → `makeSourceRecord` returns `nil` → dropped (no session failure). Post-record hint: "App audio ({X}) captured nothing — was it playing?" Relaunch is transparent (bundleID re-resolution).

---

## 8. Permissions notes

- **No new entitlement, no new TCC prompt.** Verified: `com.apple.security.app-sandbox = false`, `com.apple.security.device.audio-input = true`, `NSAudioCaptureUsageDescription` present. Per-app taps surface under the *same* audio-capture permission as the shipped global tap.
- **Availability gate is enforced by the C function, not the Swift initializer.** `CATapDescription` is annotated `API_AVAILABLE(macos(12.0))`; the per-app mixdown initializers carry **no** call-site availability annotation, so `CATapDescription(stereoMixdownOfProcesses:)` **compiles below 14.2** and fails only at `AudioHardwareCreateProcessTap` (`macos(14.2)`). **Therefore the `.app` case MUST be wrapped in `#available(macOS 14.4, *)`** in `CaptureSourceFactory` (same guard already on `.systemGlobal`) — do not rely on the type-checker. Keep the project's 14.4 floor (safely above 14.2).
- Do **not** flip `.isExclusive` on include-list descriptions.

---

## 9. Edge cases + test plan

### Correctness fixes (verified against `VoiceInkEngine.swift:342–408`)

- **BUG 1 — primary-by-index (BLOCKING).** `handleMultiSourceStop` uses `records.first` for the saved file/duration (lines 352, 366, 373), and in the degrade branch transcribes `records.first` while **deleting every other WAV** (`for extra in records.dropFirst()`, 394–396). Records only contain sources that produced frames, so index 0 is not positionally stable. With user reorder, a `.app`/`.systemGlobal` at slot 0 means: on cloud-model degrade VoiceInk transcribes app/system audio as the primary and **deletes the user's mic recording** — silent data loss. **Fix:** select `primary = first record whose source kind is .microphone (else records.first)`; transcribe/save that; delete only non-primary WAVs. Update the `AudioSourceConfig`/`CaptureSourceFactory` header comments that claim "the engine never changes."
- **BUG 2 — duplicate roles corrupt merge.** `TranscriptMerger.composeFlatText` groups by role string; two "Them" sources interleave under one header. **Fix:** enforce unique non-empty roles in `AudioSourcesViewModel.add`/`setRole`.
- **BUG 3 — same physical device duplication.** `nil` (default) + explicit-UID-equal-to-default are the same mic with different identities; UID-string dedup misses it. **Fix:** resolve `nil`→concrete default UID before the dedup comparison; block/warn.
- **All-sources-invalid (start vs frames).** `noSourcesStarted` only covers total **start** failure (already degrades to single-source in `tryStartMultiSource`). The zero-**frames** case hits `guard let primary = records.first else { …idle; return }` (line 352) and today produces **no transcript at all** — contradicting the §7 "mic-only fallback" promise. **Fix:** in the empty-`records` branch, run the mic-only single-source pipeline (or correct the UX copy to "recording discarded").

### Non-fatal runtime edge cases
- **App quits mid-record:** process object invalidates, IOProc stops, writer keeps its frames → short/`nil` record; **no crash, silent truncation.** Documented; post-record hint fires. No auto-rebuild.
- **Mic unplugged mid-record:** independent recorder stops delivering → short/zero record dropped. Safe *because* no aggregate.
- **App with helper processes (Chrome/Slack/Discord/Electron):** bundle-ID-only resolution can return **zero** matches for an actively-playing app → false "Not playing." Handled by PID+helper-PID resolution (§4); must be tested before claiming "app audio" works.

### Test plan
**Unit / logic**
1. `resolveMicDeviceID`: valid UID → real ID; stale UID → `noErr`+`0` → throws `uidNotFound` (not silent 0).
2. `resolveProcessObjects`: running audio app → ≥1 objectID; not-running → empty (no throw); self-PID excluded.
3. Role uniqueness: adding a 2nd "Them" is rejected; empty role rejected.
4. Same-device dedup: `nil`-default + explicit-default-UID → blocked; two entries same explicit UID → blocked.
5. Soft-cap: Add disabled at 4; warning shown at 4.
6. Primary selection: records `[app, mic]` (app at 0) → primary is the mic record; degrade transcribes mic, deletes app WAV, mic WAV survives.
7. Empty records → mic-only fallback path produces a transcript.

**Integration (device required)**
8. Per-app tap on a **non-Chromium** app (Music) → non-empty WAV; transcript labeled correctly.
9. Per-app tap on **Chrome/Slack** playing audio → confirm helper-PID resolution yields frames; if not, document + fall back to system-global suggestion.
10. Per-app **routed to non-default output** (app→AirPods, system default→speakers) → verify frames arrive; if silent, switch per-app anchor to app's output device.
11. Two independent mics: distinct t0-aligned tracks; confirm cross-talk caveat renders; confirm no aggregate created.
12. Reorder app-source to slot 0, force cloud model → **mic recording preserved** (regression guard for BUG 1).
13. macOS < 14.4 (or simulated): `.app`/`.systemGlobal` disabled in UI; factory throws `systemAudioUnavailable`; mic-only records.
14. Configured app never plays during a session → session succeeds, that source contributes nothing, post-record "captured nothing" hint shown.
15. N=4 sources, 5-min recording → per-source "X of N" progress advances; total latency ≈ N× and is surfaced, not silent.

**Permissions**
16. Fresh install, audio-capture TCC not yet granted → inline `lock.shield` warning; granting then recording taps successfully; confirm **no new/extra** prompt beyond the existing global-tap one.

**Safe-as-is (no change needed):** `stereoMixdownOfProcesses` primitive; no-new-entitlement/TCC conclusion; resolve-at-record-time; independent-recorder-per-mic; `AudioProcessEnumerator`; `AudioSourcesViewModel`↔`saveConfigs` persistence.