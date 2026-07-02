// SpeakerDiarizationService — on-device speaker diarization of one source WAV via
// FluidAudio (pyannote segmentation + WeSpeaker embeddings, CoreML/ANE). Actor-shaped like
// ParakeetTranscriptionService: loads are deduped and `performCompleteDiarization`
// (synchronous, CPU/ANE-bound) runs on the actor executor — never on the main actor.
//
// Two entry points with deliberately different network policies:
// - `prepareModels()` MAY download (cache-first) — called from explicit contexts only
//   (settings toggle, record-start warm-up).
// - `diarize(audioURL:)` is CACHE-ONLY — it runs inside the post-recording pipeline, which
//   must never block on network I/O (codebase convention: Parakeet loads from cache
//   in-pipeline too). Missing models throw immediately and the assembler degrades to
//   ground-truth role labels.

import Foundation
import FluidAudio
import os

actor SpeakerDiarizationService {

    static let shared = SpeakerDiarizationService()

    enum DiarizationError: LocalizedError {
        case modelsNotDownloaded
        var errorDescription: String? {
            switch self {
            case .modelsNotDownloaded:
                return "Speaker-detection models are not downloaded yet"
            }
        }
    }

    private var manager: DiarizerManager?
    private var prepareTask: Task<Void, Error>?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SpeakerDiarization")

    /// Download (cache-first) and initialize the diarizer models. The ONLY entry point
    /// allowed to hit the network; concurrent callers share one in-flight task. Callers
    /// must surface failure to the user (the settings toggle flips itself back off).
    func prepareModels() async throws {
        if manager != nil { return }
        if let prepareTask { return try await prepareTask.value }
        let task = Task<Void, Error> {
            let models = try await DiarizerModels.download()
            let ready = DiarizerManager()
            ready.initialize(models: models)
            manager = ready
            logger.notice("Diarizer models downloaded + loaded")
        }
        prepareTask = task
        defer { prepareTask = nil }
        try await task.value
    }

    /// Diarize a 16 kHz mono WAV into speaker-attributed time ranges on the WAV's own
    /// 0-based timeline. Cache-only: throws `.modelsNotDownloaded` without touching the
    /// network when models are missing. Cluster ids restart at "1" for every call —
    /// per-recording numbering is guaranteed by resetting the speaker database each run.
    func diarize(audioURL: URL) async throws -> [SegmentSpeakerLabeler.SpeakerRange] {
        let manager = try await cachedManager()
        let samples = try WAVSampleReader.samples(from: audioURL)
        // Fresh speaker database per file: the online manager otherwise carries cluster ids
        // across consecutive recordings in one app session.
        manager.speakerManager.reset(keepIfPermanent: false)
        let result = try manager.performCompleteDiarization(samples)
        logger.notice("Diarized \(samples.count, privacy: .public) samples → \(result.segments.count, privacy: .public) ranges, \(Set(result.segments.map(\.speakerId)).count, privacy: .public) speakers")
        return result.segments.map {
            SegmentSpeakerLabeler.SpeakerRange(speakerId: $0.speakerId,
                                               start: TimeInterval($0.startTimeSeconds),
                                               end: TimeInterval($0.endTimeSeconds))
        }
    }

    /// Initialize the manager from already-downloaded model files, or throw. Never downloads.
    private func cachedManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let dir = DiarizerModels.defaultModelsDirectory()
        let segmentation = dir.appendingPathComponent(ModelNames.Diarizer.segmentationFile)
        let embedding = dir.appendingPathComponent(ModelNames.Diarizer.embeddingFile)
        guard FileManager.default.fileExists(atPath: segmentation.path),
              FileManager.default.fileExists(atPath: embedding.path) else {
            logger.error("Diarizer models missing at \(dir.path, privacy: .public) — degrading to role labels")
            throw DiarizationError.modelsNotDownloaded
        }
        let models = try await DiarizerModels.load(localSegmentationModel: segmentation,
                                                   localEmbeddingModel: embedding)
        let ready = DiarizerManager()
        ready.initialize(models: models)
        manager = ready
        logger.notice("Diarizer models loaded from cache")
        return ready
    }
}
