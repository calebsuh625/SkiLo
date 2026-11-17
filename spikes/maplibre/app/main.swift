// Heavenly 3D map spike: SwiftUI macOS app hosting MapLibre GL JS in a WKWebView.
// Build (no xcodebuild needed):
//   export DEVELOPER_DIR=/Library/Developer/CommandLineTools
//   swiftc -parse-as-library -target arm64-apple-macosx15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -O main.swift -o Spike
// Run:  ./Spike            (self-exits after SPIKE_CAPTURE_SEC+3 s unless SPIKE_AUTOEXIT=0)
// Env:  SPIKE_DIR, SPIKE_CAPTURE_SEC (default 12), SPIKE_AUTOEXIT (0 keeps it open), SPIKE_CLICK (trail name)
import AppKit
import Foundation
import SwiftUI
import WebKit

let env = ProcessInfo.processInfo.environment
let spikeDir = URL(fileURLWithPath: env["SPIKE_DIR"] ?? "/Users/calebsuh/Projects/HeavenlyTracker/spikes/maplibre")
let webDir = spikeDir.appendingPathComponent("web")
let outDir = spikeDir.appendingPathComponent("out")
let captureDelay: Double = Double(env["SPIKE_CAPTURE_SEC"] ?? "12") ?? 12
let autoExit = env["SPIKE_AUTOEXIT"] != "0"
let clickTarget = env["SPIKE_CLICK"] ?? "Gunbarrel"
let keepOnTop = env["SPIKE_KEEP_ON_TOP"] != "0"
let startTime = Date()

func log(_ s: String) {
    let ts = String(format: "%6.2f", Date().timeIntervalSince(startTime))
    print("[swift +\(ts)s] \(s)")
    fflush(stdout)
}

func jsonString(_ obj: Any, limit: Int = 1500) -> String {
    var s: String
    if JSONSerialization.isValidJSONObject(obj),
       let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let str = String(data: d, encoding: .utf8) {
        s = str
    } else {
        s = String(describing: obj)
    }
    if s.count > limit { s = String(s.prefix(limit)) + "...(\(s.count) chars)" }
    return s
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { log("writePNG: conversion failed"); return }
    do {
        try png.write(to: url)
        log("wrote \(url.path) (\(png.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh)px)")
    } catch { log("writePNG error: \(error)") }
}

// MARK: - JS -> Swift bridge (window.webkit.messageHandlers.bridge.postMessage)
final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var lastClickedId: Int?
    var lastClickedName: String?
    var messageCounts: [String: Int] = [:]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { log("bridge <- (non-dict) \(message.body)"); return }
        let type = body["type"] as? String ?? "?"
        messageCounts[type, default: 0] += 1
        if type == "trailClick", let id = body["id"] as? Int {
            lastClickedId = id
            lastClickedName = body["name"] as? String
            log("*** TRAIL CLICK via bridge: \(body["name"] ?? "?") (osm way \(id)) ***")
        }
        log("bridge <- \(jsonString(body))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { log("nav didFinish: \(webView.url?.absoluteString ?? "-")") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("nav didFail: \(error.localizedDescription)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("nav didFailProvisional: \(error.localizedDescription)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { log("WebContent process TERMINATED") }
}

// MARK: - Timeline driver (Swift -> JS via evaluateJavaScript, captures, exit)
final class Driver {
    let bridge = Bridge()
    weak var webView: WKWebView?
    private var started = false

    func eval(_ js: String, label: String, _ then: ((Any?) -> Void)? = nil) {
        guard let wv = webView else { log("eval(\(label)): no webview"); return }
        wv.evaluateJavaScript(js) { result, error in
            if let error = error { log("eval(\(label)) ERROR: \(error.localizedDescription)") }
            else { log("eval(\(label)) -> \(result.map { jsonString($0, limit: 400) } ?? "undefined")") }
            then?(result)
        }
    }
    func evalLong(_ js: String, label: String) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(js) { result, error in
            if let error = error { log("eval(\(label)) ERROR: \(error.localizedDescription)") }
            else { log("eval(\(label)) -> \(result.map { jsonString($0, limit: 4000) } ?? "undefined")") }
        }
    }
    func after(_ s: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block) }

    func start(_ wv: WKWebView) {
        guard !started else { return }
        started = true
        webView = wv
        let t = captureDelay
        // WebKit suspends requestAnimationFrame (and so MapLibre's render loop, load/idle events and
        // style-update application) while the hosting window is occluded. Log occlusion changes.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow {
                log("window occlusion changed: visible=\(w.occlusionState.contains(.visible)) key=\(w.isKeyWindow) appActive=\(NSApp.isActive)")
                if !w.occlusionState.contains(.visible) && keepOnTop { w.orderFrontRegardless(); log("re-ordered window to front") }
            }
        }
        // Other windows popping up during an automated run occlude us and WebKit then suspends rAF;
        // keep the spike window floating so the map keeps rendering (SPIKE_KEEP_ON_TOP=0 disables).
        if keepOnTop { after(0.3) { if let w = NSApp.windows.first { w.level = .floating; w.orderFrontRegardless() } } }
        after(1) { self.logWindowState("t+1s") }
        after(t - 5) { self.logWindowState("before bench/click") }
        after(t - 4) { self.eval("spike.simulateClick(\(jsonString([clickTarget]).dropFirst().dropLast()))", label: "simulateClick") }
        after(t - 3) {
            if let id = self.bridge.lastClickedId { self.eval("spike.markDone(\(id))", label: "markDone(\(id))") }
            else { log("no trailClick message arrived from JS; skipping markDone") }
        }
        after(t - 2) { self.evalLong("JSON.stringify(spike.diag())", label: "diag") }
        after(t) { self.capture() }
        after(t + 3) {
            log("bridge message counts: \(self.bridge.messageCounts)")
            log("last trail click: \(self.bridge.lastClickedName ?? "NONE") id=\(self.bridge.lastClickedId.map(String.init) ?? "-")")
            if autoExit { log("exiting"); exit(0) }
        }
    }

    func logWindowState(_ label: String) {
        let w = NSApp.windows.first
        log("window state (\(label)): visible=\(w?.occlusionState.contains(.visible) ?? false) onScreen=\(w?.isOnActiveSpace ?? false) key=\(w?.isKeyWindow ?? false) appActive=\(NSApp.isActive) frame=\(w?.frame ?? .zero)")
    }

    func capture() {
        logWindowState("at capture")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // 1. Real window screenshot via /usr/sbin/screencapture (needs Screen Recording TCC for the responsible process).
        if let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            let path = outDir.appendingPathComponent("screenshot.png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
            do {
                try p.run(); p.waitUntilExit()
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                log("screencapture exit=\(p.terminationStatus) windowNumber=\(win.windowNumber) frame=\(win.frame) screen=\(win.screen?.frame ?? .zero) -> \(path) (\(size) bytes)")
            } catch { log("screencapture launch failed: \(error)") }
        } else { log("screencapture: NSApp has no window") }
        // 2. WKWebView.takeSnapshot (no TCC needed; composites web content including WebGL canvas).
        if let wv = webView {
            wv.takeSnapshot(with: nil) { image, error in
                if let image = image { writePNG(image, to: outDir.appendingPathComponent("snapshot_webview.png")) }
                else { log("takeSnapshot error: \(error?.localizedDescription ?? "nil")") }
            }
        }
        // 3. WebGL canvas pixels via toDataURL (preserveDrawingBuffer: true).
        eval("spike.canvasPNG().length", label: "canvasPNG length")
        eval("spike.canvasPNG()", label: "canvasPNG") { result in
            guard let s = result as? String, let comma = s.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { log("canvasPNG: no data"); return }
            let url = outDir.appendingPathComponent("canvas.png")
            do { try data.write(to: url); log("wrote \(url.path) (\(data.count) bytes)") } catch { log("canvas.png write error: \(error)") }
        }
    }
}

// MARK: - SwiftUI
struct MapWebView: NSViewRepresentable {
    let driver: Driver
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(driver.bridge, name: "bridge")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = driver.bridge
        let html = webDir.appendingPathComponent("index.html")
        log("loadFileURL \(html.path) allowingReadAccessTo \(webDir.path)")
        wv.loadFileURL(html, allowingReadAccessTo: webDir)
        driver.start(wv)
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ContentView: View {
    let driver: Driver
    var body: some View {
        MapWebView(driver: driver)
            .frame(minWidth: 1280, minHeight: 800)
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                log("window appeared; capture scheduled at +\(captureDelay)s")
            }
    }
}

@main
struct SpikeApp: App {
    let driver = Driver()
    var body: some Scene {
        WindowGroup("Heavenly 3D map spike - MapLibre GL JS in WKWebView") {
            ContentView(driver: driver)
        }
        .defaultSize(width: 1280, height: 800)
    }
}
