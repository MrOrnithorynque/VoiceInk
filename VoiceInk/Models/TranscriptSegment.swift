// TranscriptSegment — one labeled, timestamped span of a multi-source transcript.
// Value type persisted as JSON on `Transcription.segmentsJSON`; promoted to a
// SwiftData @Model only if/when we need to query over segments (Phase 6).

import Foundation

/// A single span of transcribed speech attributed to one capture source.
///
/// `start`/`end` are in seconds on the *shared recording timeline* (t=0 at record
/// start), already shifted by the source's `t0Offset` at merge time — so segments
/// from different sources sort into one correct conversational order.
struct TranscriptSegment: Codable, Hashable, Identifiable {
    /// Display speaker label. Ground-truth from the capture source ("Me", "Them", …) by
    /// default; when the opt-in on-device diarizer ran on this segment's source track it is
    /// a cluster label instead ("Speaker 1", or a user-chosen name) and `clusterId` is set.
    var speaker: String
    /// Cleaned segment text (filter/format/word-replace already applied per-segment).
    var text: String
    /// Seconds from record start.
    var start: TimeInterval
    /// Seconds from record start.
    var end: TimeInterval
    /// Stable diarization cluster key (`"<role>#<diarizer speakerId>"`), nil when the label
    /// is ground-truth-by-source. Optional so pre-diarization rows decode as nil.
    var clusterId: String?

    var id: String { "\(speaker)-\(start)-\(end)" }

    init(speaker: String, text: String, start: TimeInterval, end: TimeInterval,
         clusterId: String? = nil) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
        self.clusterId = clusterId
    }

    /// `[mm:ss]` timestamp prefix used when composing the flat labeled transcript.
    var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
