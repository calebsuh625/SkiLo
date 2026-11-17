import SwiftUI

extension Bundle {
    /// On iPhone the trail catalog is copied straight into the app bundle.
    static var appResources: Bundle { .main }
}

@main
@MainActor
struct SkiLoPhoneApp: App {
    @State private var accounts = AccountManager.bootstrap()

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = accounts.store {
                    PhoneRootView()
                        .environment(store)
                        .id(accounts.sessionID)            // fresh view state per account
                } else {
                    ScrollView { AccountGateView().padding(.top, 40) }
                        .scrollDismissesKeyboard(.interactively)
                }
            }
            .environment(accounts)
        }
    }
}

/// Tabs mirror the Mac sidebar (`SidebarSection`), so shared code that sets `store.section`
/// (e.g. "Map ▸" links on Progress) switches tabs here too. `.log` is the "Me" tab.
struct PhoneRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.section) {
            Tab("Map", systemImage: "map.fill", value: SidebarSection.map) { PhoneMapView() }
            Tab("Trails", systemImage: "list.bullet", value: SidebarSection.trails) { PhoneTrailsView() }
            Tab("Bucket", systemImage: "star.fill", value: SidebarSection.bucket) { PhoneBucketView() }
                .badge(store.bucketBadgeCount)
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: SidebarSection.progress) {
                NavigationStack { ProgressScreen() }
            }
            Tab("Me", systemImage: "person.crop.circle", value: SidebarSection.log) { PhoneProfileView() }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast) { if store.toast?.id == toast.id { store.toast = nil } }
                    .id(toast.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast?.id)
        .sheet(item: $store.logRunRequest) { PhoneLogRunSheet(request: $0) }
        .sheet(isPresented: $store.showOnboarding) {
            ScrollView { OnboardingSheet().environment(store) }
                .interactiveDismissDisabled()
        }
        .onAppear { store.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in store.undoManager = new }
    }
}
