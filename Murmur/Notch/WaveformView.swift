import SwiftUI

/// A row of capsule bars whose heights track the recent audio levels.
struct WaveformView: View {
    let levels: [CGFloat]
    var color: Color = .white
    var maxHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: max(3, levels[index] * maxHeight))
            }
        }
        .frame(height: maxHeight, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}
