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

## Fast incremental build (the dev loop — reuses `.local-build`, unlike `make local` which wipes it)

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

⚠️ **`CODE_SIGN_ENTITLEMENTS` MUST be an absolute path** (`$(pwd)/…`). A relative path is applied
to every SPM package target too and resolves against *their* dirs → `Build input file cannot be
found: …/AXSwift/VoiceInk/VoiceInk.local.entitlements` and BUILD FAILED.

## Running unit tests

```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig -destination 'platform=macOS' \
  -only-testing:VoiceInkTests/TranscriptMergerTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  MACOSX_DEPLOYMENT_TARGET=14.4 SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD'
```

⚠️ **`MACOSX_DEPLOYMENT_TARGET=14.4` is required for tests.** The `VoiceInkTests` target's
deployment target is macOS 14.0 but the app module is 14.4, so `@testable import VoiceInk`
fails with *"module 'VoiceInk' has a minimum deployment target of macOS 14.4"* unless you bump
it on the command line. Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not
XCTest. Pure-logic suites: `TranscriptMergerTests`, `TranscriptExportTests`.

## Gotchas

- **New source files auto-include — do NOT edit `project.pbxproj`.** The project is `objectVersion = 77` and uses Xcode's **file-system-synchronized groups** (`PBXFileSystemSynchronizedRootGroup`); individual `.swift` files are not listed in `project.pbxproj` (e.g. `CoreAudioRecorder.swift` appears 0 times). Any `.swift` file placed under `VoiceInk/` is automatically part of the target. Just create the file. (Hand-editing `project.pbxproj` to add file refs is unnecessary and risks corrupting it.)
- **Two entitlements files**: `VoiceInk/VoiceInk.entitlements` (normal builds) and `VoiceInk/VoiceInk.local.entitlements` (`make local`). Any new capability (e.g. a new audio/TCC entitlement) must be added to **both**.
- SPM dependencies (FluidAudio, Sparkle, KeyboardShortcuts, LLMkit, etc.) resolve into `.local-build/SourcePackages/` for local builds — don't edit those checkouts.
- Prefer `make local` then `open ~/Downloads/VoiceInk.app`; to confirm a UI/behavior change actually works, use the **/run** or **/verify** skills.
