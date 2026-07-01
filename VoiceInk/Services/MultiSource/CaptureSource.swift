// CaptureSource — the uniform capture abstraction for multi-source recording. The mic
// (via MicCaptureSource) and system/app audio (via SystemAudioTapRecorder) both conform,
// so MultiSourceCaptureCoordinator drives N sources by array iteration and Phase-5 source
// kinds slot in without touching the coordinator. Control plane only — it says nothing
// about the real-time callback, so it never crosses the RT boundary.

import Foundation

/// A single time-aligned capture stream that writes a 16 kHz / mono / Int16 WAV.
@MainActor
protocol CaptureSource: AnyObject {
    /// Speaker label applied to every segment from this source ("Me", "Them", …).
    var role: String { get }

    /// Whether this source captures system/app output (vs. a microphone). The coordinator
    /// keys media-control behavior on whether *any* active source is a tap.
    var isSystemTap: Bool { get }

    /// Input device name, when this source is a microphone (for `AudioSourceRecord`).
    var deviceName: String? { get }

    /// Tapped app bundle id, when this source is per-app audio (Phase 5).
    var processBundleID: String? { get }

    /// Live input level in dB (for per-source recorder meters and "no audio" detection).
    var averagePower: Float { get }
    var peakPower: Float { get }

    /// Start capturing to `url`; register the first buffer's host time with `timeline`
    /// so this stream can be aligned onto the shared recording timeline.
    func start(toOutputFile url: URL, timeline: RecordingTimeline) async throws

    /// Stop capturing and finalize the WAV.
    func stop() async

    /// The source record after `stop()`, or nil if it never produced audio (e.g. tap
    /// failed to deliver buffers). `t0Offset` is derived from the first-buffer host time.
    func makeSourceRecord() -> AudioSourceRecord?
}
