// ConversationTranscriptView — renders a merged multi-source transcript as interleaved,
// per-speaker-tinted turns with [mm:ss] timestamps. Consecutive same-speaker segments are
// grouped into one turn. Shown for `Transcription.hasSegments` rows in the result popup and
// History detail; single-source/legacy rows keep the classic Original/Enhanced rendering.

import SwiftUI

struct ConversationTranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: turn.speaker))
                            .frame(width: 8, height: 8)
                        Text(turn.speaker)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(color(for: turn.speaker))
                        Text(turn.timecode)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(turn.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color(for: turn.speaker).opacity(0.08))
                )
            }
        }
    }

    // MARK: - Turn grouping

    private struct Turn: Identifiable {
        let id = UUID()
        let speaker: String
        let timecode: String
        let text: String
    }

    /// Group consecutive same-speaker segments into one visual turn.
    private var turns: [Turn] {
        var result: [Turn] = []
        var speaker: String?
        var timecode = ""
        var parts: [String] = []

        func flush() {
            guard let speaker, !parts.isEmpty else { return }
            result.append(Turn(speaker: speaker, timecode: timecode, text: parts.joined(separator: " ")))
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
        return result
    }

    private var speakerOrder: [String] {
        var seen: [String] = []
        for seg in segments where !seen.contains(seg.speaker) { seen.append(seg.speaker) }
        return seen
    }

    private func color(for speaker: String) -> Color {
        SpeakerPalette.color(speakerOrder.firstIndex(of: speaker) ?? 0)
    }
}
