// RecordingTimeline — the single guardrail that unifies multiple capture streams onto
// one clock. A mach_absolute_time() anchor is taken BEFORE any stream starts; each
// source reports the host time of its first buffer, and its t0Offset is the seconds
// between the anchor and that first buffer. NEVER compare raw mSampleTime across
// independent devices — host time is the only cross-device-safe reference.

import Foundation
import os

/// Thread-safe shared clock for multi-source capture.
///
/// Concurrency: the anchor is written once on the main thread (pre-start) and read from
/// audio threads; `firstHostTime` for each source is written once on that source's audio
/// thread. Access is guarded by `OSAllocatedUnfairLock` — the same lightweight-lock-in-
/// the-audio-path pattern the existing `CoreAudioRecorder` meter code already uses.
final class RecordingTimeline: @unchecked Sendable {

    private let anchor = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// mach ticks → seconds, computed once from the timebase.
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }()

    /// Capture the current host time without touching any lock — safe to call from a
    /// real-time audio callback when the supplied `AudioTimeStamp.mHostTime` is invalid.
    static func currentHostTime() -> UInt64 { mach_absolute_time() }

    /// Take the shared anchor. Call exactly once, on the main thread, immediately before
    /// starting any capture source.
    func anchorNow() {
        anchor.withLock { $0 = mach_absolute_time() }
    }

    /// Whether the anchor has been set.
    var isAnchored: Bool {
        anchor.withLock { $0 != 0 }
    }

    /// Seconds between the shared anchor and `hostTime`. Returns 0 (rather than a wrong
    /// negative) if the anchor is unset or `hostTime` precedes it — callers treat a
    /// suspicious 0 offset as a warning, not silent mis-interleaving.
    func offsetSeconds(forHostTime hostTime: UInt64) -> TimeInterval {
        let anchorTime = anchor.withLock { $0 }
        guard anchorTime != 0, hostTime >= anchorTime else { return 0 }
        return Double(hostTime - anchorTime) * Self.secondsPerTick
    }
}
