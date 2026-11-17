import SwiftUI
struct StatusGlyph: View {
    let status: TrailStatus
    init(status: TrailStatus) { self.status = status }
    var body: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Ramp.doneGreen.color)
        case .bucket: Image(systemName: "star.fill").foregroundStyle(Ramp.bucketYellow.color)
        case .notDone: Image(systemName: "circle").foregroundStyle(.clear)
        }
    }
}
