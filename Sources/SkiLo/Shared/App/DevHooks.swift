import Foundation

/// Scripted-state hooks (DESIGN §11). Only active when an HT_* variable is set.
enum DevHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var isScripted: Bool { env["HT_SCREENSHOT"] != nil }
    static var skipOnboarding: Bool { env["HT_SHOW_ONBOARDING"] == "1" ? false : (isScripted || env["HT_SKIP_ONBOARDING"] == "1") }
    static var userDataDirectory: URL? { env["HT_USERDATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var catalogURL: URL? { env["HT_CATALOG"].map { URL(fileURLWithPath: $0) } }
}
