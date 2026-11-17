import SwiftUI
struct RatingPill: View {
    let rating: Int; let isOverride: Bool; let size: Font
    init(rating: Int, isOverride: Bool = false, size: Font = .title2) { self.rating = rating; self.isOverride = isOverride; self.size = size }
    var body: some View {
        let bg = Ramp.color(for: rating)
        HStack(spacing: 2) {
            Text("\(rating)").font(size.weight(.bold)).monospacedDigit()
            if isOverride { Image(systemName: "pencil").font(.caption) }
        }
        .foregroundStyle(Ramp.textColor(on: bg).color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(bg.color, in: Capsule())
    }
}
