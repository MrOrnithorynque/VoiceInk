---
name: building-voiceink
description: Build, sign, run, or package the VoiceInk macOS app, or debug build failures (whisper.xcframework linking, code signing, entitlements, "make local" vs "make build"). Use whenever a task requires compiling or launching VoiceInk, or resolving Xcode/xcodebuild/Makefile errors.
---

# Building VoiceInk

VoiceInk is an Xcode project (`VoiceInk.xcodeproj`, scheme `VoiceInk`, target macOS 14.4+) that links **`whisper.xcframework`**, which is compiled from source. The Makefile automates the framework build — prefer it over raw `xcodebuild`.

## The `whisper.xcframework` dependency

- `make whisper` clones `ggerganov/whisper.cpp` into `~/VoiceInk-Dependencies/whisper.cpp` and runs `./build-xcframework.sh`, producing `~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`.
- The Xcode project expects the framework at that location. If you see linker errors about `whisper`/`ggml` symbols, the framework is missing or unbuilt → run `make setup` (or `make whisper`).
- This build is slow the first time and cached afterward. `make clean` removes the whole `~/VoiceInk-Dependencies` dir (forces a full rebuild).

## Commands (from repo root)

| Goal | Command |
|------|---------|
| Verify toolchain (git, xcodebuild, swift) | `make check` |
| Build whisper framework only | `make whisper` / `make setup` |
| Standard Debug build (default signing; `CODE_SIGN_IDENTITY=""`) | `make build` |
| **Local build, no Apple dev cert** | `make local` |
| Build + run | `make dev` |
| Launch already-built app | `make run` |
| Remove build artifacts + deps | `make clean` |

`make local` is the safest option in a dev/CI environment without signing set up. It:
- uses `LocalBuild.xcconfig` and `VoiceInk.local.entitlements` (stripped: no CloudKit / keychain groups),
- ad-hoc signs (`CODE_SIGN_IDENTITY="-"`, `CODE_SIGNING_REQUIRED=NO`),
- defines the `LOCAL_BUILD` Swift compilation condition (used for conditional code — e.g. disabling iCloud sync),
- builds into `.local-build/` and copies `VoiceInk.app` to `~/Downloads/`, stripping quarantine (`xattr -cr`).

Limitations of a local build: no iCloud dictionary sync, no Sparkle auto-updates.

## Raw xcodebuild (when you must)

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=VoiceInk/VoiceInk.local.entitlements build
```

Tests: `xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk test` (suites in `VoiceInkTests/`, `VoiceInkUITests/` — currently minimal).

## Gotchas

- **New source files** must be added to the `VoiceInk` target in `VoiceInk.xcodeproj`, not just dropped in the folder, or they are silently not compiled. When adding files programmatically, update `project.pbxproj` accordingly.
- **Two entitlements files**: `VoiceInk/VoiceInk.entitlements` (normal builds) and `VoiceInk/VoiceInk.local.entitlements` (`make local`). Any new capability (e.g. a new audio/TCC entitlement) must be added to **both**.
- SPM dependencies (FluidAudio, Sparkle, KeyboardShortcuts, LLMkit, etc.) resolve into `.local-build/SourcePackages/` for local builds — don't edit those checkouts.
- Prefer `make local` then `open ~/Downloads/VoiceInk.app`; to confirm a UI/behavior change actually works, use the **/run** or **/verify** skills.
