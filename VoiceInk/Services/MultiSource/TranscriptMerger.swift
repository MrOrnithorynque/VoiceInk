// TranscriptMerger — pure, N-source-ready interleave of per-source segments into one
// ordered, speaker-labeled transcript. Each source's whisper segments are 0-based within
// its own WAV; they are cleaned (per-segment, so the composed [mm:ss] text never passes
// through the bracket-stripping output filter), shifted by the source's t0Offset onto the
// shared timeline, flat-mapped, and sorted. No I/O, no whisper — unit-testable in isolation.

import Foundation

enum TranscriptMerger {

    /// A source and the raw (0-based, unlabeled) segments its WAV produced.
    struct SourceSegments {
        let record: AudioSourceRecord
        let segments: [TranscriptSegment]
    }

    /// Merge per-source segments into one ordered `[TranscriptSegment]`.
    /// - Parameter clean: per-segment text transform (filter/format/word-replace), applied
    ///   BEFORE composition. Kept as a closure so this function stays pure and testable.
    ///
    /// A raw segment's `speaker` is normally empty (conformers return `speaker: ""`) and gets
    /// the source's role; a non-empty `speaker` — set by the opt-in diarization stage before
    /// merge — survives untouched, as does its `clusterId`.
    static func merge(_ sources: [SourceSegments], clean: (String) -> String) -> [TranscriptSegment] {
        sources
            .flatMap { source -> [TranscriptSegment] in
                source.segments.compactMap { seg in
                    let text = clean(seg.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptSegment(
                        speaker: seg.speaker.isEmpty ? source.record.role : seg.speaker,
                        text: text,
                        start: seg.start + source.record.t0Offset,
                        end: seg.end + source.record.t0Offset,
                        clusterId: seg.clusterId
                    )
                }
            }
            .sorted { $0.start < $1.start }
    }

    /// Compose the flat labeled transcript used for `Transcription.text`, paste, search, and
    /// CSV export. Consecutive same-speaker segments are grouped under one `[mm:ss] Role:`
    /// header. This string is built from already-cleaned segments and is never re-filtered.
    static func composeFlatText(_ segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var currentSpeaker: String?
        var buffer: [String] = []
        var blockStart: TranscriptSegment?

        func flush() {
            guard let blockStart, !buffer.isEmpty else { return }
            lines.append("[\(blockStart.timecode)] \(blockStart.speaker): \(buffer.joined(separator: " "))")
        }

        for seg in segments {
            if seg.speaker != currentSpeaker {
                flush()
                currentSpeaker = seg.speaker
                buffer = [seg.text]
                blockStart = seg
            } else {
                buffer.append(seg.text)
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }
}
