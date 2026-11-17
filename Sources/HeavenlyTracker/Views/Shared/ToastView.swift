import SwiftUI

/// Capsule toast, top-right. Auto-dismisses after `toast.autoDismissSeconds` (the sleeping task is
/// cancelled automatically when the toast is replaced or the view disappears: newest wins).
struct ToastView: View {
    let toast: Toast; let dismiss: () -> Void
    init(toast: Toast, dismiss: @escaping () -> Void) { self.toast = toast; self.dismiss = dismiss }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(tint).font(.body.weight(.semibold))
            Text(toast.text).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            ForEach(toast.actions) { action in
                Button(action.title) { action.handler(); dismiss() }
                    .buttonStyle(.borderless).font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(toast.autoDismissSeconds))
            if !Task.isCancelled { dismiss() }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch toast.kind {
        case .info: .secondary
        case .done: Ramp.doneGreen.color
        case .bucket: Ramp.bucketYellow.color
        case .milestone: .orange
        case .error: .red
        }
    }
}
