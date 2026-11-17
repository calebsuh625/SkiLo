import AppKit
import Foundation

/// Headless verification hook. If `HT_SCREENSHOT=/path/to/out.png` is set in the
/// environment, the app polls for its first visible window (SwiftUI creates it shortly after
/// launch, but timing varies under load), waits `HT_SCREENSHOT_DELAY` seconds more for layout,
/// captures it with `/usr/sbin/screencapture -l <windowNumber>`, writes a sidecar `<png>.txt`
/// with the resource-bundle status, and exits 0. Non-zero exit codes: 2 = no window within
/// `HT_SCREENSHOT_TIMEOUT` (default 20 s), 3 = screencapture failed, 4 = could not spawn it.
/// Used by `make verify`.
enum SelfCapture {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["HT_SCREENSHOT"], !out.isEmpty else { return }
        let settle = Double(env["HT_SCREENSHOT_DELAY"] ?? "") ?? 1.5
        let timeout = Double(env["HT_SCREENSHOT_TIMEOUT"] ?? "") ?? 20.0
        let deadline = Date().addingTimeInterval(timeout)
        waitForWindow(deadline: deadline) { window in
            guard let window else {
                log("no window to capture after \(timeout)s (NSApp.windows.count=\(NSApp.windows.count))")
                exit(2)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                capture(window, to: out)
            }
        }
    }

    private static func waitForWindow(deadline: Date, _ done: @escaping (NSWindow?) -> Void) {
        func poll() {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 0 }) {
                done(w); return
            }
            if Date() > deadline { done(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
    }

    private static func capture(_ window: NSWindow, to out: String) {
        try? ResourceCheck.summary.write(toFile: out + ".txt", atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out]
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 { log("screencapture exited \(proc.terminationStatus)") }
            exit(proc.terminationStatus == 0 ? 0 : 3)
        } catch {
            log("could not run screencapture: \(error)")
            exit(4)
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("HT_SCREENSHOT: \(s)\n".utf8))
    }
}
