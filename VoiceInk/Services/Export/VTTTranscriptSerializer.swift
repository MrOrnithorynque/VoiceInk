// VTTTranscriptSerializer — Transcription → WebVTT (.vtt). One cue per segment (subtitle
// formats want short cues), speaker as a <v Role> voice tag. Pure, no I/O.

import Foundation

enum VTTTranscriptSerializer {
    static func serialize(_ transcription: Transcription) -> String {
        var out = "WEBVTT\n\n"

        if let segments = transcription.decodedSegments, !segments.isEmpty {
            for (index, seg) in segments.enumerated() {
                let end = seg.end > seg.start ? seg.end : seg.start + 0.5   // zero-duration guard
                out += "\(index + 1)\n"
                out += "\(TranscriptTimecode.vtt(seg.start)) --> \(TranscriptTimecode.vtt(end))\n"
                out += "<v \(escape(seg.speaker))>\(escape(seg.text))\n\n"
            }
        } else {
            let end = transcription.duration > 0 ? transcription.duration : 0.5
            out += "1\n00:00:00.000 --> \(TranscriptTimecode.vtt(end))\n\(escape(transcription.text))\n\n"
        }
        return out
    }

    /// Escape the characters WebVTT treats specially in cue text.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
