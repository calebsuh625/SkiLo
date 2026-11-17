import SwiftUI
struct BandSymbol: View {
    let band: Band
    init(band: Band) { self.band = band }
    var body: some View {
        HStack(spacing: -2) {
            Image(systemName: band.symbolName)
            if band == .doubleBlack { Image(systemName: band.symbolName) }
        }
        .foregroundStyle(color)
    }
    private var color: Color {
        switch band { case .green: Color(RGBA(hex: "#34C759").nsColor); case .blue: Color(RGBA(hex: "#0A84FF").nsColor); case .black, .doubleBlack: .primary }
    }
}
