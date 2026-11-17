import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("defaultSection") private var defaultSection: String = ""
    init() {}

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 320)
    }

    private var general: some View {
        Form {
            Picker("Units", selection: Binding<Units>(
                get: { store.userData.profile.units },
                set: { new in
                    guard new != store.userData.profile.units else { return }
                    var d = store.userData; d.profile.units = new
                    store.replaceUserData(d, actionName: "Change Units")
                })) {
                Text("Imperial (mi, ft)").tag(Units.imperial)
                Text("Metric (km, m)").tag(Units.metric)
            }
            Picker("Open at launch", selection: $defaultSection) {
                Text("Last used").tag("")
                ForEach(SidebarSection.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
        }
        .formStyle(.grouped)
    }

    private var data: some View {
        Form {
            Section("Your data") {
                LabeledContent("Folder") {
                    Text(DataActions.dataDirectory.path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Reveal in Finder") { DataActions.revealDataFolder() }
                    Spacer()
                    Button("Export…") { DataActions.exportData(store) }
                    Button("Import…") { DataActions.importData(store) }
                }
            }
            Section {
                Button("Reset all user data…", role: .destructive) { DataActions.confirmReset(store) }
            } footer: {
                Text("Trail catalog and ratings are part of the app and are not affected.").font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "figure.skiing.downhill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("SkiLo").font(.title3.weight(.semibold))
                    Text("Version \(UserData.appVersion) · \(store.catalog.trails.count) trails · rating engine \(store.catalog.ratingEngineVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            AttributionView().padding(-20).padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
