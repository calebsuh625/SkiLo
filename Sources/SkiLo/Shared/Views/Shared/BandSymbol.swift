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
        switch band { case .green: RGBA(hex: "#34C759").color; case .blue: RGBA(hex: "#0A84FF").color; case .black, .doubleBlack: .primary }
    }
}
