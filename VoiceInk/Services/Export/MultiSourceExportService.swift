// MultiSourceExportService — dispatches a Transcription to the right serializer and writes it
// to a user-chosen file via NSSavePanel. All writes go through a user-selected URL (no silent
// writes); the content is only the user's own transcript/audio-derived text.

import Foundation
import AppKit

@MainActor
final class MultiSourceExportService {

    /// Pure dispatch to the format's serializer.
    static func serialize(_ transcription: Transcription, as format: TranscriptExportFormat) -> String {
        switch format {
        case .txt: return transcription.enhancedText ?? transcription.text
        case .markdown: return MarkdownTranscriptSerializer.serialize(transcription)
        case .vtt: return VTTTranscriptSerializer.serialize(transcription)
        case .srt: return SRTTranscriptSerializer.serialize(transcription)
        }
    }

    /// Present a save panel and write the serialized transcript. Returns whether it saved.
    @discardableResult
    func export(_ transcription: Transcription, as format: TranscriptExportFormat) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(TranscriptFilename.suggested(from: transcription.text)).\(format.fileExtension)"
        panel.title = "Export Transcription"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try Self.serialize(transcription, as: format).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Bulk export: one file per transcription into a user-chosen directory.
    @discardableResult
    func exportBatch(_ transcriptions: [Transcription], as format: TranscriptExportFormat) -> Int {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose a folder to export \(transcriptions.count) transcript(s)"

        guard panel.runModal() == .OK, let directory = panel.url else { return 0 }
        var saved = 0
        for (index, transcription) in transcriptions.enumerated() {
            let base = TranscriptFilename.suggested(from: transcription.text)
            let url = directory.appendingPathComponent("\(base)-\(index + 1).\(format.fileExtension)")
            if (try? Self.serialize(transcription, as: format).write(to: url, atomically: true, encoding: .utf8)) != nil {
                saved += 1
            }
        }
        return saved
    }
}
