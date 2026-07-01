// MarkdownTranscriptSerializer — Transcription → Markdown. For multi-source rows it renders a
// grouped speaker conversation (matching ConversationTranscriptView / TranscriptMerger); for
// single-source rows it renders the classic doc (subsuming AnimatedSaveButton's old markdown).

import Foundation

enum MarkdownTranscriptSerializer {
    static func serialize(_ transcription: Transcription) -> String {
        if let segments = transcription.decodedSegments, !segments.isEmpty {
            return conversation(transcription, segments)
        }
        return single(transcription)
    }

    private static func conversation(_ t: Transcription, _ segments: [TranscriptSegment]) -> String {
        var lines: [String] = ["# Conversation Transcript", ""]
        lines.append("**Date:** \(DateFormatter.localizedString(from: t.timestamp, dateStyle: .long, timeStyle: .short))")
        if t.duration > 0 { lines.append("**Duration:** \(t.duration.formatTiming())") }

        let speakers = orderedSpeakers(segments)
        if !speakers.isEmpty { lines.append("**Speakers:** \(speakers.joined(separator: ", "))") }
        if let model = t.transcriptionModelName { lines.append("**Model:** \(model)") }

        lines.append("")
        lines.append("---")
        lines.append("")

        for turn in groupedTurns(segments) {
            lines.append("**[\(turn.timecode)] \(turn.speaker):** \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private static func single(_ t: Transcription) -> String {
        var out = """
        # Transcription

        **Date:** \(DateFormatter.localizedString(from: t.timestamp, dateStyle: .long, timeStyle: .short))

        \(t.text)
        """
        if let enhanced = t.enhancedText, !enhanced.isEmpty {
            out += "\n\n## Enhanced\n\n\(enhanced)"
        }
        return out + "\n"
    }

    // MARK: - Helpers

    private static func orderedSpeakers(_ segments: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    struct Turn { let speaker: String; let timecode: String; let text: String }

    /// Group consecutive same-speaker segments into one turn (matches the on-screen rendering).
    static func groupedTurns(_ segments: [TranscriptSegment]) -> [Turn] {
        var turns: [Turn] = []
        var speaker: String?
        var timecode = ""
        var parts: [String] = []

        func flush() {
            guard let speaker, !parts.isEmpty else { return }
            turns.append(Turn(speaker: speaker, timecode: timecode, text: parts.joined(separator: " ")))
        }
        for seg in segments {
            if seg.speaker != speaker {
                flush()
                speaker = seg.speaker
                timecode = seg.timecode
                parts = [seg.text]
            } else {
                parts.append(seg.text)
            }
        }
        flush()
        return turns
    }
}
