import SwiftUI
import AppKit

@main
@MainActor
struct HeavenlyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var accounts = AccountManager.bootstrap()
    /// Menus need a store even while signed out; this one is empty and never saved.
    @State private var signedOutStore = AppStore(catalog: (try? CatalogLoader.loadBundled()) ?? .empty, userData: .fresh(), persistence: nil)

    var body: some Scene {
        WindowGroup("Heavenly Tracker") {
            Group {
                if let store = accounts.store {
                    RootView()
                        .environment(store)
                        .id(accounts.sessionID)            // fresh view state per account
                        .onAppear { DevHooks.apply(to: store) }
                } else {
                    AccountGateView()
                }
            }
            .environment(accounts)
            .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(store: accounts.store ?? signedOutStore) }

        Settings {
            SettingsView().environment(accounts.store ?? signedOutStore)
        }
    }
}
