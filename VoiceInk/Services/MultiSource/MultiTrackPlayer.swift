// MultiTrackPlayer — synchronized playback of a multi-source recording's N per-source WAVs on
// one shared timeline. Uses a single AVAudioEngine with one AVAudioPlayerNode per source, all
// started against ONE shared AVAudioTime host-time anchor (mirroring RecordingTimeline's
// "one anchor before any stream" invariant on the capture side), so tracks stay sample-locked
// and cannot drift relative to each other. Each source is placed by its t0Offset.

import Foundation
import AVFoundation
import os

@MainActor
final class MultiTrackPlayer: ObservableObject {

    struct LoadedSource: Identifiable {
        let id: String            // AudioSourceRecord.id (file URL string)
        let role: String
        let colorIndex: Int
        let t0Offset: TimeInterval
        let fileDuration: TimeInterval
        let file: AVAudioFile
    }

    @Published private(set) var loaded: [LoadedSource] = []
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var perSourceWaveforms: [String: [Float]] = [:]
    @Published var isLoadingWaveforms = false
    /// Sources whose WAV file is missing on disk (cleanup ran) — shown as unavailable.
    @Published private(set) var missingRoles: [String] = []

    private let engine = AVAudioEngine()
    private var nodes: [String: AVAudioPlayerNode] = [:]
    private var timer: Timer?
    private var seekBase: TimeInterval = 0
    private var startHostTime: UInt64 = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiTrackPlayer")

    // MARK: - Load

    func load(sources: [AudioSourceRecord]) {
        cleanup()
        var loaded: [LoadedSource] = []
        var missing: [String] = []

        for (index, record) in sources.enumerated() {
            guard FileManager.default.fileExists(atPath: record.fileURL.path),
                  let file = try? AVAudioFile(forReading: record.fileURL) else {
                missing.append(record.role)
                continue
            }
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            nodes[record.id] = node
            loaded.append(LoadedSource(id: record.id, role: record.role, colorIndex: index,
                                       t0Offset: record.t0Offset, fileDuration: fileDuration, file: file))
        }

        self.loaded = loaded
        self.missingRoles = missing
        self.duration = loaded.map { $0.t0Offset + $0.fileDuration }.max() ?? 0
        loadWaveforms(loaded)
    }

    private func loadWaveforms(_ sources: [LoadedSource]) {
        guard !sources.isEmpty else { return }
        isLoadingWaveforms = true
        Task {
            var result: [String: [Float]] = [:]
            for source in sources {
                result[source.id] = await WaveformGenerator.generateWaveformSamples(from: source.file.url)
            }
            self.perSourceWaveforms = result
            self.isLoadingWaveforms = false
        }
    }

    // MARK: - Transport

    func play() {
        guard !loaded.isEmpty else { return }
        if currentTime >= duration { currentTime = 0 }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            schedule(from: currentTime)
            isPlaying = true
            startTimer()
        } catch {
            logger.error("Failed to start playback engine: \(error.localizedDescription, privacy: .public)")
            isPlaying = false
        }
    }

    func pause() {
        for node in nodes.values { node.pause() }
        isPlaying = false
        stopTimer()
    }

    func seek(to shared: TimeInterval) {
        let clamped = min(max(0, shared), duration)
        currentTime = clamped
        guard isPlaying else { return }
        // Stop-all + reschedule-all from the new position keeps every track sample-locked.
        for node in nodes.values { node.stop() }
        schedule(from: clamped)
    }

    /// Schedule every node against one shared start anchor; each source begins after its own
    /// (t0Offset − seekTime) so all tracks line up on the shared clock.
    private func schedule(from seekTime: TimeInterval) {
        let startHost = mach_absolute_time() + hostTicks(0.05)   // ~50 ms lead
        startHostTime = startHost
        seekBase = seekTime

        for source in loaded {
            guard let node = nodes[source.id] else { continue }
            node.stop()

            let localSeek = seekTime - source.t0Offset
            guard localSeek < source.fileDuration else { continue }   // this source already ended

            let fileSampleRate = source.file.processingFormat.sampleRate
            let framePos = AVAudioFramePosition(max(0, localSeek) * fileSampleRate)
            let framesToPlay = source.file.length - framePos
            guard framesToPlay > 0 else { continue }

            node.scheduleSegment(source.file, startingFrame: framePos,
                                 frameCount: AVAudioFrameCount(framesToPlay), at: nil, completionHandler: nil)

            let deferSeconds = max(0, source.t0Offset - seekTime)   // late-entry sources
            let nodeStart = AVAudioTime(hostTime: startHost + hostTicks(deferSeconds))
            node.play(at: nodeStart)
        }
    }

    // MARK: - Progress

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = mach_absolute_time()
        let elapsed = now > startHostTime ? seconds(now - startHostTime) : 0
        currentTime = min(seekBase + elapsed, duration)
        if currentTime >= duration {
            for node in nodes.values { node.stop() }
            isPlaying = false
            stopTimer()
            currentTime = 0
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        stopTimer()
        for node in nodes.values {
            node.stop()
            engine.detach(node)
        }
        nodes.removeAll()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        currentTime = 0
    }

    // MARK: - Host-time helpers

    private func hostTicks(_ seconds: Double) -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ns = seconds * 1_000_000_000
        return UInt64(ns * Double(tb.denom) / Double(tb.numer))
    }

    private func seconds(_ ticks: UInt64) -> TimeInterval {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }
}
