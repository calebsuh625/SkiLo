import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    init() {}
    var body: some View {
        List(selection: Binding<SidebarSection?>(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
            ForEach(SidebarSection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(section == .bucket ? store.bucketBadgeCount : 0)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            AccountHeader().padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniProgressCard().padding(10)
        }
    }
}
