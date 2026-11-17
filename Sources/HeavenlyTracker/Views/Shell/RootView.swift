import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @AppStorage("defaultSection") private var defaultSection: String = ""
    @State private var appliedDefaultSection = false
    init() {}

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            content
                .inspector(isPresented: $store.inspectorShown) {
                    TrailInspector().inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                }
                .searchable(text: $store.filter.searchText, placement: .toolbar, prompt: "Search trails")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                            .help("Show or hide the Inspector (⌥⌘I)")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast) { if store.toast?.id == toast.id { store.toast = nil } }
                    .id(toast.id)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast?.id)
        .sheet(item: $store.logRunRequest) { LogRunSheet(request: $0) }
        .sheet(isPresented: $store.showOnboarding) { OnboardingSheet().environment(store) }
        .onKeyPress(.escape) {
            guard store.selection != nil else { return .ignored }
            store.select(nil, showInspector: false)
            return .handled
        }
        .onAppear {
            store.undoManager = undoManager
            if !appliedDefaultSection {
                appliedDefaultSection = true
                if let s = SidebarSection(rawValue: defaultSection) { store.section = s }
            }
        }
        .onChange(of: undoManager) { _, new in store.undoManager = new }
    }

    @ViewBuilder private var content: some View {
        switch store.section {
        case .map: MapScreen()
        case .trails: TrailsScreen()
        case .bucket: BucketScreen()
        case .progress: ProgressScreen()
        case .log: LogScreen()
        }
    }
}
