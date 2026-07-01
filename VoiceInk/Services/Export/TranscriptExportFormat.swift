// TranscriptExportFormat — the transcript export formats and shared timecode/filename helpers
// used by the Markdown/VTT/SRT serializers. Pure, no I/O.

import Foundation
import UniformTypeIdentifiers

enum TranscriptExportFormat: String, CaseIterable {
    case txt
    case markdown
    case vtt
    case srt

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .vtt: return "WebVTT (.vtt)"
        case .srt: return "SubRip (.srt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .vtt: return "vtt"
        case .srt: return "srt"
        }
    }

    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .plainText
    }
}

/// HH:MM:SS timecodes for subtitle formats (VTT uses a dot, SRT a comma).
enum TranscriptTimecode {
    static func vtt(_ t: TimeInterval) -> String { format(t, separator: ".") }
    static func srt(_ t: TimeInterval) -> String { format(t, separator: ",") }

    private static func format(_ t: TimeInterval, separator: String) -> String {
        let total = max(0, t)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let millis = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, millis)
    }
}

/// Suggests a filename from transcript text (first several words, sanitized). Lifted from the
/// former `AnimatedSaveButton.generateFileName` so the save button and export service agree.
enum TranscriptFilename {
    static func suggested(from text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        let words = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "transcription" }

        let wordCount = min(words.count, words.count <= 3 ? words.count : (words.count <= 6 ? 6 : 8))
        let fileName = words.prefix(wordCount).joined(separator: "-")
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return fileName.isEmpty ? "transcription" : String(fileName.prefix(50))
    }
}
