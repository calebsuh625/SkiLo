import SwiftUI

/// Edit a ski day's title / conditions / notes (`UserData.skiDays`).
struct EditDaySheet: View {
    @Environment(AppStore.self) private var store
    let dayKey: String
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var conditions: Conditions? = nil
    @State private var notes = ""

    init(dayKey: String, isPresented: Binding<Bool>) { self.dayKey = dayKey; self._isPresented = isPresented }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit ski day").font(.title3.weight(.semibold))
            Text(dayKey).foregroundStyle(.secondary).monospacedDigit()
            LabeledContent("Title") { TextField("e.g. Bluebird after storm", text: $title).textFieldStyle(.roundedBorder) }
            LabeledContent("Conditions") {
                Picker("Conditions", selection: $conditions) {
                    Text("Not set").tag(Conditions?.none)
                    ForEach(Conditions.allCases, id: \.self) { Text($0.label).tag(Conditions?.some($0)) }
                }.labelsHidden().frame(maxWidth: 200)
            }
            LabeledContent("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setSkiDayMeta(dayKey, SkiDayMeta(title: title.trimmingCharacters(in: .whitespaces), conditions: conditions, notes: notes))
                    isPresented = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear {
            let m = store.userData.skiDays[dayKey] ?? SkiDayMeta()
            title = m.title; conditions = m.conditions; notes = m.notes
        }
    }
}
