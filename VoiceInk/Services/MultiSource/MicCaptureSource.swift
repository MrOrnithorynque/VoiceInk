// MicCaptureSource — CaptureSource adapter over CoreAudioRecorder for the microphone.
// Deliberately drives CoreAudioRecorder DIRECTLY rather than the single-source `Recorder`,
// so the multi-source path never triggers Recorder's mute-system-audio / pause-media
// behavior (which would silence or pause the very app we're capturing). The single-source
// `Recorder` is left completely untouched.

import Foundation
import CoreAudio
import os

@MainActor
final class MicCaptureSource: CaptureSource {

    let role: String
    var isSystemTap: Bool { false }
    private(set) var deviceName: String?
    var processBundleID: String? { nil }

    /// Persisted device UID to record (Phase 5); nil = current default input.
    private let deviceUID: String?

    private let recorder = CoreAudioRecorder()
    private let deviceManager = AudioDeviceManager.shared
    private let setupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.mic-source.setup", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MicCaptureSource")

    private weak var timeline: RecordingTimeline?
    private var fileURL: URL?
    /// First-buffer host time, written once from the audio thread, read after stop.
    private let firstHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    var averagePower: Float { recorder.averagePower }
    var peakPower: Float { recorder.peakPower }

    init(role: String, deviceUID: String? = nil) {
        self.role = role
        self.deviceUID = deviceUID
    }

    func start(toOutputFile url: URL, timeline: RecordingTimeline) async throws {
        self.timeline = timeline
        self.fileURL = url

        // Resolve a persisted device UID → AudioDeviceID (IDs aren't stable across reconnects);
        // fall back to the current default input.
        let deviceID: AudioDeviceID
        if let deviceUID, let resolved = deviceManager.availableDevices.first(where: { $0.uid == deviceUID })?.id {
            deviceID = resolved
        } else {
            deviceID = deviceManager.getCurrentDevice()
        }
        self.deviceName = deviceManager.availableDevices.first(where: { $0.id == deviceID })?.name

        let hostTimeLock = firstHostTime
        recorder.onFirstBufferHostTime = { host in
            hostTimeLock.withLock { if $0 == 0 { $0 = host } }
        }

        let recorder = self.recorder
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setupQueue.async {
                do {
                    try recorder.startRecording(toOutputFile: url, deviceID: deviceID)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        logger.notice("🎙️ Mic source '\(self.role, privacy: .public)' started on device \(deviceID, privacy: .public)")
    }

    func stop() async {
        let recorder = self.recorder
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            setupQueue.async {
                recorder.stopRecording()
                cont.resume()
            }
        }
    }

    func makeSourceRecord() -> AudioSourceRecord? {
        guard let fileURL else { return nil }
        let host = firstHostTime.withLock { $0 }
        let offset = (host != 0) ? (timeline?.offsetSeconds(forHostTime: host) ?? 0) : 0
        if host == 0 {
            logger.warning("🎙️ Mic source '\(self.role, privacy: .public)' never reported a host time; t0Offset = 0")
        }
        return AudioSourceRecord(role: role, fileURL: fileURL, t0Offset: offset, deviceName: deviceName, kind: "mic")
    }
}
