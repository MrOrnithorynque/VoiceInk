import SwiftUI
import UniformTypeIdentifiers

struct AnimatedSaveButton: View {
    let textToSave: String
    /// When set, exports route through `MultiSourceExportService` (and multi-source rows also
    /// offer VTT/SRT). When nil, the legacy raw-text TXT/MD save is used.
    var transcription: Transcription? = nil

    @State private var isSaved: Bool = false

    var body: some View {
        Menu {
            Button("Save as TXT") { handleSave(.txt) }
            Button("Save as MD") { handleSave(.markdown) }
            if transcription?.isMultiSource == true {
                Button("Save as VTT") { handleSave(.vtt) }
                Button("Save as SRT") { handleSave(.srt) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSaved ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: 12, weight: isSaved ? .bold : .regular))
                    .foregroundColor(.white)
                Text(isSaved ? "Saved" : "Save")
                    .font(.system(size: 12, weight: isSaved ? .medium : .regular))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSaved ? Color.green.opacity(0.8) : Color.orange)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSaved ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSaved)
    }

    private func handleSave(_ format: TranscriptExportFormat) {
        let saved: Bool
        if let transcription {
            saved = MultiSourceExportService().export(transcription, as: format)
        } else {
            saved = saveRawText(format)
        }
        guard saved else { return }
        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { isSaved = false }
        }
    }

    /// Legacy path for callers that only have text (no Transcription).
    private func saveRawText(_ format: TranscriptExportFormat) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(TranscriptFilename.suggested(from: textToSave)).\(format.fileExtension)"
        panel.title = "Save Transcription"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let content = (format == .markdown) ? legacyMarkdown(textToSave) : textToSave
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to save file: \(error.localizedDescription)")
            return false
        }
    }

    private func legacyMarkdown(_ text: String) -> String {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        return """
        # Transcription

        **Date:** \(timestamp)

        \(text)
        """
    }
}

struct AnimatedSaveButton_Previews: PreviewProvider {
    static var previews: some View {
        AnimatedSaveButton(textToSave: "Hello world this is a sample transcription text")
            .padding()
    }
}
