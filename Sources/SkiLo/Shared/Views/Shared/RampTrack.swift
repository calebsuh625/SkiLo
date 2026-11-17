import SwiftUI

/// The 1–100 colour ramp as a horizontal gradient.
struct RampTrack: View {
    var body: some View {
        LinearGradient(stops: Ramp.stops.map { .init(color: $0.color.color, location: Double($0.rating - 1) / 99) },
                       startPoint: .leading, endPoint: .trailing)
    }
}
