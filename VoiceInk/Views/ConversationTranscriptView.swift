// ConversationTranscriptView — renders a merged multi-source transcript as interleaved,
// per-speaker-tinted turns with [mm:ss] timestamps. Consecutive same-speaker segments are
// grouped into one turn. Shown for `Transcription.hasSegments` rows in the result popup and
// History detail; single-source/legacy rows keep the classic Original/Enhanced rendering.

import SwiftUI

struct ConversationTranscriptView: View {
    let segments: [TranscriptSegment]
    /// Optional rename hook `(oldLabel, newLabel)`. When set (History detail), every turn
    /// header gets a "Rename speaker…" context menu; read-only surfaces pass nil.
    var onRenameSpeaker: ((String, String) -> Void)? = nil

    @State private var renameTarget: String?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turn in
                turnView(turn)
            }
        }
        .alert("Rename speaker", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renameTarget {
                    onRenameSpeaker?(renameTarget, renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Applies to every line spoken by \u{201C}\(renameTarget ?? "")\u{201D} in this transcript.")
        }
    }

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        let base = VStack(alignment: .leading, spacing: 4) {
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

        if onRenameSpeaker != nil {
            base.contextMenu {
                Button("Rename \u{201C}\(turn.speaker)\u{201D}…") {
                    renameText = turn.speaker
                    renameTarget = turn.speaker
                }
            }
        } else {
            base
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
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
