// MultiSourceVoiceCountView — the compact "N voices" pill shown in the mini/notch recorder
// during a multi-source (Conversation Mode) recording, in place of the single-voice waveform.
// Collapsed it shows just a glyph + the source count (+ a warning tint if any source has gone
// silent, so a dead mic/tap is still visible at a glance). Tapping opens a popover with one live
// level bar per source (reusing MultiSourceLevelBarsView) to confirm each input is producing audio.

import SwiftUI

struct MultiSourceVoiceCountView: View {
    let levels: [MultiSourceLevel]
    @State private var showDetails = false

    private var anySilent: Bool { levels.contains { $0.isSilent } }

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(levels.count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
                if anySilent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.orange)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(levels.count) audio sources — click to view levels")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Capturing \(levels.count) \(levels.count == 1 ? "source" : "sources")")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                MultiSourceLevelBarsView(levels: levels)
                    .frame(width: 150)
            }
            .padding(12)
        }
    }
}
