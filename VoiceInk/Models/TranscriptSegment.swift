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
    /// Ground-truth speaker label derived from the capture source ("Me", "Them", …) —
    /// never an ML diarization guess.
    var speaker: String
    /// Cleaned segment text (filter/format/word-replace already applied per-segment).
    var text: String
    /// Seconds from record start.
    var start: TimeInterval
    /// Seconds from record start.
    var end: TimeInterval

    var id: String { "\(speaker)-\(start)-\(end)" }

    init(speaker: String, text: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }

    /// `[mm:ss]` timestamp prefix used when composing the flat labeled transcript.
    var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
