// MultiSourceCaptureCoordinator — drives N CaptureSources on one shared timeline. Takes a
// single mach_absolute_time() anchor BEFORE starting any source (so every source's t0Offset
// is measured from the same instant), starts all, and on stop returns each source's
// AudioSourceRecord. Degrades gracefully: sources that fail to start are dropped and the
// session proceeds as long as ≥1 started (so a tap failure falls back to mic-only).
//
// Note on the mute/pause self-collision: the multi-source sources drive CoreAudioRecorder /
// the process tap directly and NEVER touch MediaController/PlaybackController, so — unlike
// the single-source `Recorder` — nothing here mutes system output or pauses the app being
// captured. There is nothing to "suppress": it is avoided by construction.

import Foundation
import os

@MainActor
final class MultiSourceCaptureCoordinator {

    enum CoordinatorError: LocalizedError {
        case noSourcesStarted
        var errorDescription: String? {
            switch self {
            case .noSourcesStarted: return "No audio sources could be started"
            }
        }
    }

    private let sources: [CaptureSource]
    private let timeline = RecordingTimeline()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiSourceCaptureCoordinator")

    private(set) var startedSources: [CaptureSource] = []
    private var startedURLs: [URL] = []
    private(set) var isActive = false

    init(sources: [CaptureSource]) {
        self.sources = sources
    }

    /// True if any configured source captures system/app output (drives, e.g., the
    /// "keeps other apps playing" settings note and future media-control decisions).
    var hasSystemTap: Bool { sources.contains { $0.isSystemTap } }

    /// Live per-source meters for the recorder UI (role + normalized level).
    var sourceMeters: [(role: String, average: Float, peak: Float)] {
        startedSources.map { ($0.role, $0.averagePower, $0.peakPower) }
    }

    /// Start all sources against one shared pre-start anchor.
    /// - Parameter urlFor: supplies the output WAV URL for each (source, index).
    /// - Throws: `CoordinatorError.noSourcesStarted` only if every source failed.
    func start(urlFor: (CaptureSource, Int) -> URL) async throws {
        timeline.anchorNow()   // one anchor, before any stream starts

        var started: [CaptureSource] = []
        var startedURLs: [URL] = []
        for (index, source) in sources.enumerated() {
            let url = urlFor(source, index)
            do {
                try await source.start(toOutputFile: url, timeline: timeline)
                started.append(source)
                startedURLs.append(url)
            } catch {
                logger.error("Source '\(source.role, privacy: .public)' failed to start: \(error.localizedDescription, privacy: .public) — dropping")
            }
        }

        guard !started.isEmpty else { throw CoordinatorError.noSourcesStarted }
        if started.count < sources.count {
            logger.notice("Degraded capture: \(started.count, privacy: .public)/\(self.sources.count, privacy: .public) sources started")
        }
        startedSources = started
        self.startedURLs = startedURLs
        isActive = true
    }

    /// Stop all started sources and return their records (dropping any that produced nothing).
    func stop() async -> [AudioSourceRecord] {
        for source in startedSources { await source.stop() }
        let records = startedSources.compactMap { $0.makeSourceRecord() }
        isActive = false
        return records
    }

    /// Cancel: stop everything and delete every WAV we handed a source — including zero-frame
    /// files (a silent tap still created its file), which `makeSourceRecord()` would skip.
    func cancel() async {
        for source in startedSources { await source.stop() }
        for url in startedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        startedSources = []
        startedURLs = []
        isActive = false
    }

    /// Delete every WAV we handed a source, after `stop()` — used when the session produced
    /// nothing usable, so zero-frame files aren't left behind as orphans.
    func discardStartedFiles() {
        for url in startedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        startedURLs = []
    }
}
