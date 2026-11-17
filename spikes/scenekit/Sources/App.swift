import SwiftUI
import AppKit

@main
struct SpikeApp: App {
    @StateObject private var model = SpikeModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Heavenly SceneKit Spike") {
            ContentView(model: model).frame(minWidth: 1280, minHeight: 800)
        }
    }
}
