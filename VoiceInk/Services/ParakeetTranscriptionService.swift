// ParakeetTranscriptionService — batch transcription via FluidAudio's Parakeet CoreML models.
// An ACTOR: the service is shared (registry singleton) and its methods run off the main actor
// (pipeline, multi-source assembly, warm-up tasks), so asrManager/cachedModels/loadingTask need
// serialization. Actors are reentrant across awaits, so cleanup is additionally coordinated with
// in-flight transcriptions (`inFlightTranscriptions`/`pendingCleanup`): tearing down AsrManager
// mid-`transcribe` (e.g. user cancels a Conversation-Mode session during assembly) would race
// FluidAudio's CoreML state.

import Foundation
import CoreML
import AVFoundation
import FluidAudio
import os.log

actor ParakeetTranscriptionService: TranscriptionService, SegmentingTranscriptionService {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink.parakeet", category: "ParakeetTranscriptionService")

    /// Transcriptions currently awaiting FluidAudio; cleanup is deferred while > 0.
    private var inFlightTranscriptions = 0
    /// Set when cleanup() arrives mid-transcription; honoured by the last one to finish.
    private var pendingCleanup = false

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        model.name.lowercased().contains("v2") ? .v2 : .v3
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        asrManager?.cleanup()
        asrManager = nil
        vadManager = nil
        activeVersion = nil

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.activeVersion = version
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            try await AsrModels.loadFromCache(
                configuration: nil,
                version: version
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: ParakeetModel) async throws {
        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        beginTranscription()
        defer { endTranscription() }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let audioSamples = try readAudioSamples(from: audioURL)

        let durationSeconds = Double(audioSamples.count) / 16000.0
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")

        var speechAudio = audioSamples
        if durationSeconds >= 20.0, isVADEnabled {
            let vadConfig = VadConfig(defaultThreshold: 0.7)
            if vadManager == nil {
                do {
                    vadManager = try await VadManager(config: vadConfig)
                } catch {
                    logger.notice("VAD init failed; falling back to full audio: \(error.localizedDescription, privacy: .public)")
                    vadManager = nil
                }
            }

            if let vadManager {
                do {
                    let segments = try await vadManager.segmentSpeechAudio(audioSamples)
                    speechAudio = segments.isEmpty ? audioSamples : segments.flatMap { $0 }
                } catch {
                    logger.notice("VAD segmentation failed; using full audio: \(error.localizedDescription, privacy: .public)")
                    speechAudio = audioSamples
                }
            }
        }

        // Pad with 1s of silence to capture final punctuation at sequence boundary
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        let result = try await asrManager.transcribe(speechAudio)

        return result.text
    }

    // MARK: - SegmentingTranscriptionService

    /// Transcribe with per-segment timestamps for the multi-source (Conversation Mode) path.
    /// Unlike `transcribe(...)`, this deliberately skips the ≥20s VAD trimming so token times map
    /// linearly to the raw WAV (the same VAD-off requirement whisper honours via forceDisableVAD),
    /// then groups FluidAudio's token timings into readable segments. The role is left empty —
    /// `TranscriptMerger` stamps each source's role.
    func transcribeWithSegments(audioURL: URL, model: any TranscriptionModel) async throws -> [TranscriptSegment] {
        beginTranscription()
        defer { endTranscription() }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        var speechAudio = try readAudioSamples(from: audioURL)

        // Trailing-silence pad (mirrors transcribe()) to capture final punctuation; it appends to
        // the end so it never shifts earlier timestamps. No VAD trimming — that would warp times.
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        let result = try await asrManager.transcribe(speechAudio)

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No token timings (e.g. empty/near-silent source): fall back to one whole-file segment
            // so a non-empty transcript still participates in the merge.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptSegment(speaker: "", text: text, start: 0, end: result.duration)]
        }

        // Token `endTime`s are synthesized (next token's start) — ParakeetSegmentGrouper clamps
        // them; see its header before changing this seam.
        let tokens = timings.map { TimedToken(token: $0.token, start: $0.startTime, end: $0.endTime) }
        return ParakeetSegmentGrouper.group(tokens)
    }

    /// Decode the WAV via the RIFF-walking shared reader (Apple's writer inserts a FLLR chunk;
    /// a fixed 44-byte offset would bias every token timestamp ~0.13s late).
    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            return try WAVSampleReader.samples(from: url)
        } catch {
            throw ASRError.invalidAudioData
        }
    }

    // MARK: - Cleanup (coordinated with in-flight transcriptions)

    private func beginTranscription() {
        inFlightTranscriptions += 1
    }

    private func endTranscription() {
        inFlightTranscriptions -= 1
        if pendingCleanup && inFlightTranscriptions == 0 {
            pendingCleanup = false
            performCleanup()
        }
    }

    /// Release ASR/VAD resources (cached models are preserved for reuse). If a transcription is
    /// in flight, the teardown is deferred until it finishes rather than yanking AsrManager's
    /// CoreML state out from under it.
    func cleanup() {
        guard inFlightTranscriptions == 0 else {
            pendingCleanup = true
            logger.notice("cleanup deferred: \(self.inFlightTranscriptions, privacy: .public) transcription(s) in flight")
            return
        }
        performCleanup()
    }

    private func performCleanup() {
        asrManager?.cleanup()
        asrManager = nil
        vadManager = nil
        activeVersion = nil
    }

}
