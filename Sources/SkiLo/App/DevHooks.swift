import Foundation
import AppKit

/// Scripted-state hooks (DESIGN §11). Only active when an HT_* variable is set.
enum DevHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var isScripted: Bool { env["HT_SCREENSHOT"] != nil }
    static var skipOnboarding: Bool { env["HT_SHOW_ONBOARDING"] == "1" ? false : (isScripted || env["HT_SKIP_ONBOARDING"] == "1") }
    static var userDataDirectory: URL? { env["HT_USERDATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var catalogURL: URL? { env["HT_CATALOG"].map { URL(fileURLWithPath: $0) } }

    @MainActor
    static func apply(to store: AppStore) {
        let e = env
        guard e.keys.contains(where: { $0.hasPrefix("HT_") }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let s = e["HT_SECTION"], let section = SidebarSection(rawValue: s) { store.section = section }
            if let s = e["HT_BASE_STYLE"], let style = MapBaseStyle(rawValue: s) { store.mapBaseStyle = style }
            if let ids = e["HT_BUCKET"] { store.addToBucket(ids.split(separator: ",").map(String.init)) }
            if let id = e["HT_SELECT"] { store.select(id, showInspector: true) }
            if let c = e["HT_CAMERA"] {
                switch c {
                case "overview":      store.requestCamera(.overview)
                case "california":    store.requestCamera(.california)
                case "nevada":        store.requestCamera(.nevada)
                case "mottKillebrew": store.requestCamera(.mottKillebrew)
                case "fit":           if let id = e["HT_SELECT"] { store.requestCamera(.fit(id)) }
                default: break
                }
            }
            if let ids = e["HT_MARK_DONE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    for id in ids.split(separator: ",") { store.markDone(String(id)) }
                }
            }
        }
    }
}
