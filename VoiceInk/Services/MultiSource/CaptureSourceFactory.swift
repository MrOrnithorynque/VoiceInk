// CaptureSourceFactory — maps declarative AudioSourceConfigs to live CaptureSources. This
// is the seam that keeps source-kind knowledge out of VoiceInkEngine: v1 hands it a
// hard-coded [mic, system] array; Phase 5 hands it a user-configured array decoded from
// UserDefaults and the engine never changes — only new `case`s are added here.

import Foundation
import os

@MainActor
enum CaptureSourceFactory {

    enum FactoryError: LocalizedError {
        case systemAudioUnavailable
        case appNotCapturing(String)
        case noSourcesAvailable

        var errorDescription: String? {
            switch self {
            case .systemAudioUnavailable: return "System-audio capture requires macOS 14.4 or later"
            case .appNotCapturing(let bundleID): return "\(bundleID) has no audio to capture (not running or not playing)"
            case .noSourcesAvailable: return "None of the configured audio sources are available"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CaptureSourceFactory")

    /// Build capture sources for the given configs, degrading per-source: a config that can't
    /// be built (e.g. an app not currently playing → `.appNotCapturing`) is logged and skipped
    /// rather than aborting the whole session. Throws only if NONE could be built.
    static func makeSources(from configs: [AudioSourceConfig]) throws -> [CaptureSource] {
        var sources: [CaptureSource] = []
        for config in configs {
            do {
                sources.append(try makeSource(from: config))
            } catch {
                logger.notice("Skipping audio source '\(config.role, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !sources.isEmpty else { throw FactoryError.noSourcesAvailable }
        return sources
    }

    static func makeSource(from config: AudioSourceConfig) throws -> CaptureSource {
        switch config.kind {
        case .microphone(let deviceUID):
            return MicCaptureSource(role: config.role, deviceUID: deviceUID)

        case .systemGlobal:
            guard #available(macOS 14.4, *) else { throw FactoryError.systemAudioUnavailable }
            return SystemAudioTapRecorder(role: config.role, mode: .globalExcludingSelf)

        case .app(let bundleID):
            // Availability is enforced by the C function, not the Swift initializer — the
            // per-app CATapDescription init compiles below 14.2, so guard explicitly.
            guard #available(macOS 14.4, *) else { throw FactoryError.systemAudioUnavailable }
            let processes = AudioProcessEnumerator.resolveProcessObjects(forBundleID: bundleID)
            guard !processes.isEmpty else { throw FactoryError.appNotCapturing(bundleID) }
            return SystemAudioTapRecorder(role: config.role, mode: .processes(processes, bundleID: bundleID))
        }
    }
}
