import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    /// Per-source live levels for the recorder UI during a multi-source recording.
    @Published var multiSourceLevels: [MultiSourceLevel] = []
    var partialTranscript: String = ""
    var currentSession: TranscriptionSession?

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    /// Active multi-source session, when the two-source feature is capturing. nil on the
    /// single-source path (which is left completely unchanged).
    private var multiSourceCoordinator: MultiSourceCaptureCoordinator?
    /// Forwards the coordinator's combined level into `recorder.audioMeter` so the existing
    /// mini/notch recorder visualizer animates during a multi-source recording.
    private var multiSourceMeterTimer: Timer?
    private var meterSilentTicks: [String: Int] = [:]
    private var meterTickCount = 0

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderUIManager?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        if let enhancementService {
            PowerModeSessionManager.shared.configure(engine: self, enhancementService: enhancementService)
        }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(powerModeId: UUID? = nil) async {
        logger.notice("toggleRecord called – state=\(String(describing: self.recordingState), privacy: .public)")

        if recordingState == .recording {
            partialTranscript = ""
            recordingState = .transcribing

            // Multi-source session: stop/merge via its own path (recorder wasn't used).
            if let coordinator = multiSourceCoordinator {
                stopMultiSourceMeter()
                multiSourceCoordinator = nil
                await handleMultiSourceStop(coordinator: coordinator)
                return
            }

            await recorder.stopRecording()

            if let recordedFile {
                if !shouldCancelRecording {
                    let audioAsset = AVURLAsset(url: recordedFile)
                    let duration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

                    let transcription = Transcription(
                        text: "",
                        duration: duration,
                        audioFileURL: recordedFile.absoluteString,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(on: transcription, audioURL: recordedFile)
                } else {
                    currentSession?.cancel()
                    currentSession = nil
                    try? FileManager.default.removeItem(at: recordedFile)
                    recordingState = .idle
                    await cleanupResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                currentSession?.cancel()
                currentSession = nil
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            logger.notice("toggleRecord: entering start-recording branch")
            guard transcriptionModelManager.currentTranscriptionModel != nil else {
                NotificationManager.shared.showNotification(title: "No AI Model Selected", type: .error)
                return
            }
            shouldCancelRecording = false
            partialTranscript = ""

            requestRecordPermission { [self] granted in
                if granted {
                    Task {
                        do {
                            // Two-source path takes over when enabled + effective local model.
                            if await self.tryStartMultiSource(powerModeId: powerModeId) {
                                return
                            }

                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
                            self.recorder.onAudioChunk = { data in
                                pendingChunks.withLock { $0.append(data) }
                            }

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.recorderUIManager?.isMiniRecorderVisible ?? false, !self.shouldCancelRecording else {
                                self.recorder.stopRecording()
                                self.recordedFile = nil
                                return
                            }

                            self.recordingState = .recording
                            self.logger.notice("toggleRecord: recording started successfully, state=recording")

                            await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)

                            if self.recordingState == .recording,
                               let model = self.transcriptionModelManager.currentTranscriptionModel {
                                let session = self.serviceRegistry.createSession(
                                    for: model,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            self?.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                let realCallback = try await session.prepare(model: model)

                                if let realCallback {
                                    self.recorder.onAudioChunk = realCallback
                                    let buffered = pendingChunks.withLock { chunks -> [Data] in
                                        let result = chunks
                                        chunks.removeAll()
                                        return result
                                    }
                                    for chunk in buffered { realCallback(chunk) }
                                } else {
                                    self.recorder.onAudioChunk = nil
                                    pendingChunks.withLock { $0.removeAll() }
                                }
                            }

                            Task.detached { [weak self] in
                                guard let self else { return }

                                if let model = await self.transcriptionModelManager.currentTranscriptionModel,
                                   model.provider == .local {
                                    if let localWhisperModel = await self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                                       await self.whisperModelManager.whisperContext == nil {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            await self.logger.error("❌ Model loading failed: \(error.localizedDescription, privacy: .public)")
                                        }
                                    }
                                } else if let parakeetModel = await self.transcriptionModelManager.currentTranscriptionModel as? ParakeetModel {
                                    try? await self.serviceRegistry.parakeetTranscriptionService.loadModel(for: parakeetModel)
                                }

                                if let enhancementService = await self.enhancementService {
                                    await MainActor.run {
                                        enhancementService.captureClipboardContext()
                                    }
                                    await enhancementService.captureScreenContext()
                                }
                            }

                        } catch {
                            self.logger.error("❌ Failed to start recording: \(error.localizedDescription, privacy: .public)")
                            await NotificationManager.shared.showNotification(title: "Recording failed to start", type: .error)
                            self.logger.notice("toggleRecord: calling dismissMiniRecorder from error handler")
                            await self.recorderUIManager?.dismissMiniRecorder()
                            self.recordedFile = nil
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(on transcription: Transcription, audioURL: URL) async {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            transcription.text = "Transcription Failed: No model selected"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            return
        }

        let session = currentSession
        currentSession = nil

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            model: model,
            session: session,
            onStateChange: { [weak self] state in self?.recordingState = state },
            shouldCancel: { [weak self] in self?.shouldCancelRecording ?? false },
            onCleanup: { [weak self] in await self?.cleanupResources() },
            onDismiss: { [weak self] in await self?.recorderUIManager?.dismissMiniRecorder() }
        )

        shouldCancelRecording = false
        if recordingState != .idle {
            recordingState = .idle
        }
    }

    // MARK: - Multi-Source (two-source) Recording

    /// Attempt to start a multi-source (mic + system audio) capture session. Returns true if
    /// the two-source path has taken over the recording flow (started, or cleanly aborted);
    /// false when it is not applicable and the caller should run the single-source path.
    /// Atomic: on any failure to start, nothing is left running.
    private func tryStartMultiSource(powerModeId: UUID?) async -> Bool {
        guard UserDefaults.standard.bool(forKey: "TwoSourceTranscriptionEnabled") else { return false }
        // Conversation Mode is model-agnostic: it works with any model whose service can emit
        // per-segment timestamps (whisper OR Parakeet today). We run the selected model once per
        // source WAV and interleave by timestamp — each file is one role by default; the opt-in
        // diarization stage (ConversationDiarizationEnabled) further splits non-mic tracks.
        guard let currentModel = transcriptionModelManager.currentTranscriptionModel,
              serviceRegistry.segmentingService(for: currentModel) != nil else { return false }

        let sources: [CaptureSource]
        do {
            sources = try CaptureSourceFactory.makeSources(from: AudioSourceConfig.active)
        } catch {
            logger.notice("Multi-source unavailable, falling back to single source: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let coordinator = MultiSourceCaptureCoordinator(sources: sources)
        let sessionID = UUID().uuidString
        let directory = recordingsDirectory
        do {
            try await coordinator.start(urlFor: { _, index in
                directory.appendingPathComponent("\(sessionID)-src\(index).wav")
            })
        } catch {
            logger.error("❌ Multi-source capture failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Mirror the single-source guard: if the recorder UI was dismissed / cancelled during
        // async setup, abort this session (do not fall back — that would double-record).
        guard recorderUIManager?.isMiniRecorderVisible ?? false, !shouldCancelRecording else {
            await coordinator.cancel()
            return true
        }

        multiSourceCoordinator = coordinator
        recordingState = .recording
        startMultiSourceMeter()
        logger.notice("🎙️🔊 Multi-source recording started (\(coordinator.startedSources.count, privacy: .public) sources)")

        await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)

        // Warm the effective model in the background (mirrors the single-source path) so a cold
        // whisper/Parakeet load isn't paid inside the post-stop assembly.
        Task.detached { [weak self] in
            guard let self else { return }
            guard let model = await self.transcriptionModelManager.currentTranscriptionModel else { return }
            if model.provider == .local {
                if let localWhisperModel = await self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                   await self.whisperModelManager.whisperContext == nil {
                    try? await self.whisperModelManager.loadModel(localWhisperModel)
                }
            } else if let parakeetModel = model as? ParakeetModel {
                try? await self.serviceRegistry.parakeetTranscriptionService.loadModel(for: parakeetModel)
            }
        }

        // Same warm-up for the opt-in diarizer: (re)attempt the cache-first model download
        // WHILE recording, because the post-stop pipeline is deliberately cache-only and
        // degrades to role labels if models are missing (e.g. the settings-toggle download
        // failed offline). Errors are non-fatal here — degrade, don't block.
        if UserDefaults.standard.bool(forKey: "ConversationDiarizationEnabled") {
            Task.detached {
                try? await SpeakerDiarizationService.shared.prepareModels()
            }
        }

        // Caption bridge: open the buffering bracket so the extension starts observing.
        // Non-blocking; if the listener can't start, captions simply never arrive and the
        // transcript keeps "Speaker N" labels (meeting-name-feed-spec.md degrade rules).
        if UserDefaults.standard.bool(forKey: "CaptionBridgeEnabled") {
            Task {
                try? await CaptionBridgeServer.shared.ensureRunning()
                await CaptionBridgeServer.shared.beginSession()
            }
        }

        return true
    }

    /// Stop a multi-source session, then either assemble a merged transcript (effective local
    /// model) or degrade to the single-source pipeline on the primary (mic) WAV.
    private func handleMultiSourceStop(coordinator: MultiSourceCaptureCoordinator) async {
        if shouldCancelRecording {
            await coordinator.cancel()
            _ = await endCaptionSession()   // discard: cancelled recording
            shouldCancelRecording = false
            recordingState = .idle
            await cleanupResources()
            return
        }

        let records = await coordinator.stop()
        // Close the caption bracket on EVERY exit path below; only the assemble path will
        // consume the events (M2 resolver). Until then they are counted and dropped.
        let captionEvents = await endCaptionSession()
        guard !records.isEmpty else {
            logger.error("❌ Multi-source produced no audio — recording discarded")
            coordinator.discardStartedFiles()
            NotificationManager.shared.showNotification(
                title: "No audio captured — recording discarded",
                type: .error
            )
            recordingState = .idle
            await cleanupResources()
            return
        }
        // Primary = the microphone track (the user's own voice), chosen by kind — NEVER by
        // array position, so a reordered tap at index 0 can't cause the mic to be dropped.
        let primary = records.first(where: { $0.isMicrophone }) ?? records[0]

        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            recordingState = .idle
            await cleanupResources()
            return
        }

        let assembler = MultiSourceAssembler(serviceRegistry: serviceRegistry, modelContext: modelContext)
        let primaryDuration = await loadDuration(primary.fileURL)

        // Re-check the EFFECTIVE model (PowerMode may have swapped to cloud during recording).
        if records.count >= 2, assembler.canAssemble(model: model) {
            if !captionEvents.isEmpty {
                // M1 plumbing checkpoint — the M2 CaptionNameResolver will consume these.
                logger.notice("Collected \(captionEvents.count, privacy: .public) caption event(s); name resolution lands in M2")
            }
            let transcription = Transcription(
                text: "",
                duration: primaryDuration,
                audioFileURL: primary.fileURL.absoluteString,
                transcriptionStatus: .pending
            )
            modelContext.insert(transcription)
            try? modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

            await pipeline.runMultiSource(
                transcription: transcription,
                records: records,
                model: model,
                assembler: assembler,
                shouldCancel: { [weak self] in self?.shouldCancelRecording ?? false },
                onCleanup: { [weak self] in await self?.cleanupResources() },
                onDismiss: { [weak self] in await self?.recorderUIManager?.dismissMiniRecorder() }
            )
            shouldCancelRecording = false
            if recordingState != .idle { recordingState = .idle }
        } else {
            // Degrade: cloud/non-segmenting model or a single surviving source → transcribe
            // the mic (primary) WAV through the normal pipeline; discard the other source files.
            for extra in records where extra.fileURL != primary.fileURL {
                try? FileManager.default.removeItem(at: extra.fileURL)
            }
            let transcription = Transcription(
                text: "",
                duration: primaryDuration,
                audioFileURL: primary.fileURL.absoluteString,
                transcriptionStatus: .pending
            )
            modelContext.insert(transcription)
            try? modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            await runPipeline(on: transcription, audioURL: primary.fileURL)
        }
    }

    /// Close the caption-bridge bracket (no-op when the feature is off). Never blocks on
    /// the network — returns only what already arrived (name-feed spec, trap-6 analog).
    private func endCaptionSession() async -> [CaptionBridgeServer.CaptionEvent] {
        guard UserDefaults.standard.bool(forKey: "CaptionBridgeEnabled") else { return [] }
        return await CaptionBridgeServer.shared.endSession()
    }

    private func loadDuration(_ url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return (try? CMTimeGetSeconds(await asset.load(.duration))) ?? 0.0
    }

    /// Drive the recorder visualizer from the coordinator's combined level while recording
    /// (the multi-source path bypasses `Recorder`, whose meter would otherwise stay flat).
    private func startMultiSourceMeter() {
        multiSourceMeterTimer?.invalidate()
        meterSilentTicks = [:]
        meterTickCount = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMultiSourceMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        multiSourceMeterTimer = timer
    }

    /// Silence threshold (normalized) and how long (ticks × 0.05s) before a source is flagged
    /// as producing no audio. Only evaluated after ~2.5s so the start isn't a false positive.
    private static let meterSilenceLevel = 0.02
    private static let meterSilenceTicks = 40   // 2.0s
    private static let meterGraceTicks = 50     // 2.5s

    private func tickMultiSourceMeter() {
        guard let coordinator = multiSourceCoordinator else { return }
        let meters = coordinator.sourceMeters
        guard !meters.isEmpty else { return }
        meterTickCount += 1

        var combinedAvg: Float = -160
        var combinedPeak: Float = -160
        var levels: [MultiSourceLevel] = []
        for (index, meter) in meters.enumerated() {
            combinedAvg = max(combinedAvg, meter.average)
            combinedPeak = max(combinedPeak, meter.peak)
            let level = Double(Self.normalizeMeter(meter.peak))

            if level < Self.meterSilenceLevel {
                meterSilentTicks[meter.role, default: 0] += 1
            } else {
                meterSilentTicks[meter.role] = 0
            }
            let isSilent = meterTickCount > Self.meterGraceTicks
                && (meterSilentTicks[meter.role] ?? 0) > Self.meterSilenceTicks

            levels.append(MultiSourceLevel(role: meter.role, level: level, isSilent: isSilent, colorIndex: index))
        }

        recorder.audioMeter = AudioMeter(
            averagePower: Double(Self.normalizeMeter(combinedAvg)),
            peakPower: Double(Self.normalizeMeter(combinedPeak))
        )
        multiSourceLevels = levels
    }

    private func stopMultiSourceMeter() {
        multiSourceMeterTimer?.invalidate()
        multiSourceMeterTimer = nil
        meterSilentTicks = [:]
        meterTickCount = 0
        multiSourceLevels = []
        recorder.audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    }

    /// Map dB (−60…0) to a 0…1 level, matching Recorder's normalization.
    private static func normalizeMeter(_ db: Float) -> Float {
        let minDb: Float = -60, maxDb: Float = 0
        if db < minDb { return 0 }
        if db >= maxDb { return 1 }
        return (db - minDb) / (maxDb - minDb)
    }

    // MARK: - Resource Cleanup

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLicenseStatusChanged),
            name: .licenseStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handleLicenseStatusChanged() {
        pipeline.licenseViewModel = LicenseViewModel()
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}
