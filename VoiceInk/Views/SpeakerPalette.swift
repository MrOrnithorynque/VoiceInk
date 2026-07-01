// SpeakerPalette — one place for the per-speaker/​per-source colors, so the recorder level
// bars, the conversation transcript, and any future multi-source UI stay visually consistent.

import SwiftUI

enum SpeakerPalette {
    static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]

    static func color(_ index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        let i = ((index % colors.count) + colors.count) % colors.count
        return colors[i]
    }
}
