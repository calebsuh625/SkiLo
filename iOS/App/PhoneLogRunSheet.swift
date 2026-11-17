import SwiftUI

struct PhoneLogRunSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: LogRunRequest
    @State private var trailID: Trail.ID?
    @State private var date = Date()
    @State private var conditions: Conditions = .groomed
    @State private var confidence = 3
    @State private var notes = ""
    @State private var markDone = true

    private static let confidenceLabels = [1: "Survived it", 2: "Shaky", 3: "Solid", 4: "Confident", 5: "Owned it"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Trail", selection: $trailID) {
                        Text("Choose…").tag(Trail.ID?.none)
                        ForEach(store.catalog.trails.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { t in
                            Text("\(t.name) (\(store.effectiveRating(t)))").tag(Trail.ID?.some(t.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    DatePicker("When", selection: $date, in: ...Date())
                }
                Section {
                    Picker("Conditions", selection: $conditions) { ForEach(Conditions.allCases, id: \.self) { Text($0.label).tag($0) } }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("How did it go?")
                            Spacer()
                            Text(Self.confidenceLabels[confidence] ?? "").foregroundStyle(.secondary)
                        }
                        Picker("Confidence", selection: $confidence) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }
                            .pickerStyle(.segmented)
                    }
                } footer: {
                    Text("A clean run (3+) raises your Elo; 1–2 counts as a struggle and can lower it.")
                }
                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
                    if let id = trailID, !store.state(for: id).isDone {
                        Toggle("Mark trail as done", isOn: $markDone)
                    }
                }
            }
            .navigationTitle(request.existing == nil ? "Log Run" : "Edit Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(trailID == nil) }
            }
            .onAppear {
                trailID = request.existing?.trailID ?? request.trailID
                date = request.existing?.date ?? request.date
                if let e = request.existing { conditions = e.conditions; confidence = e.confidence; notes = e.notes }
            }
        }
    }

    private func save() {
        guard let id = trailID else { return }
        if var e = request.existing {
            e.trailID = id; e.date = date; e.conditions = conditions; e.confidence = confidence; e.notes = notes
            store.updateRun(e)
        } else {
            let e = RunLogEntry(trailID: id, date: date, conditions: conditions, confidence: confidence, notes: notes)
            store.logRun(e, alsoMarkDone: markDone && !store.state(for: id).isDone)
        }
        dismiss()
    }
}
