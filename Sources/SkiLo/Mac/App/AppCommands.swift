import SwiftUI
import AppKit
import MapKit

struct AppCommands: Commands {
    let store: AppStore
    init(store: AppStore) { self.store = store }

    private var selected: Trail? { store.selection.flatMap { store.trail($0) } }
    private var selectedDone: Bool { store.selection.map { store.state(for: $0).isDone } ?? false }
    private var selectedBucketed: Bool { store.selection.map { store.state(for: $0).bucketedAt != nil } ?? false }

    var body: some Commands {
        // File: no "New"; export / import / reveal live here instead.
        CommandGroup(replacing: .newItem) {
            Button("Export Data…") { DataActions.exportData(store) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Import Data…") { DataActions.importData(store) }.keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Reveal Data File in Finder") { DataActions.revealDataFolder() }
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { i, section in
                Button(section.title) { store.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button(store.inspectorShown ? "Hide Inspector" : "Show Inspector") { store.inspectorShown.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(store.legendShown ? "Hide Legend" : "Show Legend") { store.legendShown.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Menu("Camera") {
                Button("Overview") { store.requestCamera(.overview) }.keyboardShortcut("0", modifiers: .command)
                ForEach(Array(store.resort.views.enumerated()), id: \.offset) { i, v in
                    Button(v.title) { store.requestCamera(.camera(v.camera)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
                Divider()
                Button("Fit to Selected Trail") { if let id = store.selection { store.requestCamera(.fit(id)) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store.selection == nil)
            }
            Menu("Resort") {
                ForEach(Array(store.catalogs.enumerated()), id: \.element.id) { i, c in
                    Toggle(ResortInfo.info(for: c.id).name, isOn: Binding(get: { store.resortID == c.id }, set: { if $0 { store.switchResort(to: c.id) } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
            }
            Menu("Base Style") {
                ForEach(MapBaseStyle.allCases, id: \.self) { style in
                    Toggle(style.rawValue.capitalized, isOn: Binding(get: { store.mapBaseStyle == style }, set: { if $0 { store.mapBaseStyle = style } }))
                }
            }
            Menu("Filters") { FilterMenuContent(store: store) }
        }

        CommandMenu("Trail") {
            Button(selectedDone ? "Mark Not Done" : "Mark Done") { if let id = store.selection { store.toggleDone(id) } }
                .keyboardShortcut("d", modifiers: .command).disabled(selected == nil)
            Button("Ran It Again") { if let id = store.selection { store.recordAnotherRun(id) } }
                .keyboardShortcut("r", modifiers: .command).disabled(selected == nil || !selectedDone)
            Button(selectedBucketed ? "Remove from Bucket List" : "Add to Bucket List") { if let id = store.selection { store.toggleBucket(id) } }
                .keyboardShortcut("b", modifiers: .command).disabled(selected == nil)
            Button("Log Run…") { store.requestLogRun(trailID: store.selection) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Override Rating…") { if let id = store.selection { OverrideCoordinator.request(for: id, store: store) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(selected == nil)
            Divider()
            Button("Directions…") {
                if let id = store.selection { store.openDirections(to: .trail(id)) } else { store.openDirections() }
            }
            .keyboardShortcut("g", modifiers: .command)
            Button("Fly Through Trail") { if let id = store.selection { store.flyThrough(trail: id) } }
                .keyboardShortcut("p", modifiers: [.command, .option]).disabled(selected == nil)
            Divider()
            Button("Open in Apple Maps") {
                if let t = selected {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: t.midpoint.lat, longitude: t.midpoint.lon)))
                    item.name = t.name
                    item.openInMaps()
                }
            }.disabled(selected == nil)
            Button("Copy Trail Name") {
                if let t = selected { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.name, forType: .string) }
            }.disabled(selected == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Data & Attribution (OSM / ODbL)") { AttributionWindow.show() }
            Button("Reveal Data Folder") { DataActions.revealDataFolder() }
        }
    }
}
