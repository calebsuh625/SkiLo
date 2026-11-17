import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Panels and Finder actions shared by Settings and the File menu.
@MainActor
enum DataActions {
    static func exportData(_ store: AppStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = "HeavenlyTracker-\(f.string(from: Date())).json"
        panel.title = "Export Data"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExportImport.export(store.userData, to: url)
            store.showToast(Toast(kind: .info, text: "Exported to \(url.lastPathComponent)", symbol: "square.and.arrow.up"))
        } catch {
            store.showToast(Toast(kind: .error, text: "Export failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle", autoDismissSeconds: 8))
        }
    }

    /// Import = Replace, after confirmation showing what the file contains.
    static func importData(_ store: AppStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Data"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (data, summary) = try ExportImport.read(from: url)
            let alert = NSAlert()
            alert.messageText = "Replace your data with this file?"
            var info = "\(summary.doneCount) trails done, \(summary.runCount) logged runs, \(summary.bucketCount) on the bucket list"
            if let d = summary.earliestDate { info += ", since \(Format.date(d))" }
            alert.informativeText = info + ".\n\nYour current data will be replaced. You can undo this with Edit > Undo."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.replaceUserData(data, actionName: "Import Data")
            store.showToast(Toast(kind: .info, text: "Imported \(url.lastPathComponent)", symbol: "square.and.arrow.down"))
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not import that file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static var dataDirectory: URL { AccountManager.currentDataDirectory ?? UserDataStore.defaultDirectory() }

    static func revealDataFolder() {
        let dir = dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("userdata.json")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { NSWorkspace.shared.open(dir) }
    }

    static func confirmReset(_ store: AppStore) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset all user data?"
        alert.informativeText = "This clears every done trail, bucket list entry, logged run, note and rating override. You can undo this with Edit > Undo until you quit."
        alert.addButton(withTitle: "Reset All Data")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.resetAllUserData() }
    }
}

/// Small stand-alone window for Help > Data & Attribution.
@MainActor
enum AttributionWindow {
    private static var window: NSWindow?
    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: AttributionView().frame(width: 460)))
        w.title = "Data & Attribution"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct AttributionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data & Attribution").font(.headline)
            Text("Trail geometry, names and difficulty tags come from OpenStreetMap contributors and are available under the Open Database License (ODbL 1.0). © OpenStreetMap contributors. openstreetmap.org/copyright")
            Text("Elevation comes from AWS Terrain Tiles (Mapzen terrarium encoding), which combine public elevation sources such as SRTM and USGS 3DEP.")
            Text("The map uses Apple Maps. Map data © Apple and its data providers.")
            Text("Ratings from 1 to 100 are computed by this app from slope, vertical and terrain data, and are not an official resort rating. Always ski within your ability and follow resort signage.")
                .foregroundStyle(.secondary)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(20)
    }
}
