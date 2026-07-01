// SRTTranscriptSerializer — Transcription → SubRip (.srt). One cue per segment; SRT has no
// speaker syntax, so the role is prefixed to the line. Pure, no I/O.

import Foundation

enum SRTTranscriptSerializer {
    static func serialize(_ transcription: Transcription) -> String {
        var out = ""

        if let segments = transcription.decodedSegments, !segments.isEmpty {
            for (index, seg) in segments.enumerated() {
                let end = seg.end > seg.start ? seg.end : seg.start + 0.5   // zero-duration guard
                out += "\(index + 1)\n"
                out += "\(TranscriptTimecode.srt(seg.start)) --> \(TranscriptTimecode.srt(end))\n"
                out += "\(seg.speaker): \(seg.text)\n\n"
            }
        } else {
            let end = transcription.duration > 0 ? transcription.duration : 0.5
            out += "1\n00:00:00,000 --> \(TranscriptTimecode.srt(end))\n\(transcription.text)\n\n"
        }
        return out
    }
}
