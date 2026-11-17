import SwiftUI
import AppKit

struct MapHostView: NSViewRepresentable {
    let engine: any MapEngine
    func makeNSView(context: Context) -> NSView { engine.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
