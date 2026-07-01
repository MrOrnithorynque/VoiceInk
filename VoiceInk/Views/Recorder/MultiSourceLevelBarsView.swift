// MultiSourceLevelBarsView — compact per-source level bars shown in the mini/notch recorder
// during a multi-source recording. One tinted bar per source ("Me"/"Them"), with a live
// "no audio" warning when a source has been silent for a couple seconds (surfaces a dead mic,
// a muted app, or a failed tap while the user can still fix it).

import SwiftUI

struct MultiSourceLevelBarsView: View {
    let levels: [MultiSourceLevel]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(levels) { level in
                HStack(spacing: 4) {
                    Text(String(level.role.prefix(1)).uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(SpeakerPalette.color(level.colorIndex))
                        .frame(width: 9)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule()
                                .fill(level.isSilent ? Color.orange : SpeakerPalette.color(level.colorIndex))
                                .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level.level)))))
                        }
                    }
                    .frame(height: 4)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.orange)
                        .opacity(level.isSilent ? 1 : 0)
                        .frame(width: 8)
                        .help("No audio detected from \(level.role)")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
