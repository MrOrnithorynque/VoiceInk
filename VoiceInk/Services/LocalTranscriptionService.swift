// LocalTranscriptionService — whisper.cpp-backed transcription for `.local` models.
// Conforms to SegmentingTranscriptionService so the multi-source path can obtain
// per-segment timestamps on a VAD-disabled run without touching other providers.

import Foundation
import AVFoundation
import os

class LocalTranscriptionService: TranscriptionService, SegmentingTranscriptionService {

    private var whisperContext: WhisperContext?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any LocalModelProvider)?

    init(modelsDirectory: URL, modelProvider: (any LocalModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let (context, isShared) = try await resolveContext(for: model)
        defer { releaseIfOwned(context, isShared: isShared) }

        let data = try readAudioSamples(audioURL)
        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        await context.setPrompt(currentPrompt)

        let success = await context.fullTranscribe(samples: data)
        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await context.getTranscription()
        logger.notice("Local transcription completed successfully.")
        return text
    }

    /// Segment-level transcription on a VAD-disabled path (times are in raw-WAV seconds).
    /// `speaker` is left empty here — the capture source's role is applied at merge time.
    func transcribeWithSegments(audioURL: URL, model: any TranscriptionModel) async throws -> [TranscriptSegment] {
        let (context, isShared) = try await resolveContext(for: model)
        defer { releaseIfOwned(context, isShared: isShared) }

        let data = try readAudioSamples(audioURL)
        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        await context.setPrompt(currentPrompt)

        let success = await context.fullTranscribe(samples: data, forceDisableVAD: true)
        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full, segments).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let raw = await context.getTimestampedSegments()
        logger.notice("Local segmented transcription completed: \(raw.count, privacy: .public) segments.")
        return raw.map { TranscriptSegment(speaker: "", text: $0.text, start: $0.start, end: $0.end) }
    }

    // MARK: - Shared model loading

    /// Resolve a ready `WhisperContext` for `model`, reusing the provider's shared context
    /// when it already holds the requested model, otherwise loading a fresh one.
    /// - Returns: the context and whether it is the shared/provider-owned one.
    private func resolveContext(for model: any TranscriptionModel) async throws -> (WhisperContext, isShared: Bool) {
        guard model.provider == .local else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        if let provider = modelProvider,
           await provider.isModelLoaded,
           let loadedContext = await provider.whisperContext,
           await provider.loadedLocalModel?.name == model.name {
            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
            return (loadedContext, isShared: true)
        }

        let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
        guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Loading model: \(model.name, privacy: .public)")
        do {
            let context = try await WhisperContext.createContext(path: modelURL.path)
            whisperContext = context
            return (context, isShared: false)
        } catch {
            logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    /// Release a context only if we created it (never the provider's shared one).
    private func releaseIfOwned(_ context: WhisperContext, isShared: Bool) {
        guard !isShared else { return }
        Task { await context.releaseResources() }
        if whisperContext === context { whisperContext = nil }
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: 44, to: data.count, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
        return floats
    }
}
