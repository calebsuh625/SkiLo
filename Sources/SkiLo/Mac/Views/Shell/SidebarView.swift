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
            VStack(spacing: 6) {
                AccountHeader()
                ResortPicker()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniProgressCard().padding(10)
        }
    }
}

/// Which mountain the map, trail list, picks and planner show (⌃⌘1…3).
struct ResortPicker: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Menu {
            ForEach(store.catalogs, id: \.id) { c in
                let info = ResortInfo.info(for: c.id)
                Button {
                    store.switchResort(to: c.id)
                } label: {
                    if c.id == store.resortID { Label(info.name, systemImage: "checkmark") } else { Text(info.name) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.resort.shortName).font(.callout.weight(.semibold))
                    Text("\(store.doneCount)/\(store.catalog.trails.count) trails").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .help("Switch resort (⌃⌘1–3)")
    }
}
