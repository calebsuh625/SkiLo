import SwiftUI

/// UX_SPEC §6.2. New run, or edit when `request.existing != nil`.
struct LogRunSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: LogRunRequest

    @State private var trailID: Trail.ID?
    @State private var date: Date
    @State private var conditions: Conditions
    @State private var confidence: Int
    @State private var notes: String
    @State private var markDone = true
    @State private var pickerShown = false
    @State private var query = ""

    static let captions = [1: "Survived", 2: "Sketchy", 3: "OK, in control", 4: "Comfortable", 5: "Owned it"]

    init(request: LogRunRequest) {
        self.request = request
        let e = request.existing
        _trailID = State(initialValue: e?.trailID ?? request.trailID)
        _date = State(initialValue: e?.date ?? request.date)
        _conditions = State(initialValue: e?.conditions ?? .groomed)
        _confidence = State(initialValue: e?.confidence ?? 3)
        _notes = State(initialValue: e?.notes ?? "")
    }

    private var editing: Bool { request.existing != nil }
    private var trail: Trail? { trailID.flatMap { store.trail($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "Edit run" : "Log a run").font(.title3.weight(.semibold))
            row("Trail") {
                Button { pickerShown = true } label: {
                    HStack {
                        if let t = trail {
                            BandSymbol(band: Band.of(store.effectiveRating(t))); Text(t.name)
                            RatingPill(rating: store.effectiveRating(t), size: .caption)
                        } else { Text("Choose a trail…").foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $pickerShown) { picker }
            }
            row("When") { DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
            row("Conditions") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Conditions.allCases, id: \.self) { c in
                        Button { conditions = c } label: { Text(c.label).font(.callout).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).tint(conditions == c ? .accentColor : nil)
                            .background(conditions == c ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            row("Confidence") {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { n in
                        Button { confidence = n } label: { Image(systemName: n <= confidence ? "star.fill" : "star").foregroundStyle(.orange) }
                            .buttonStyle(.plain)
                    }
                    Text("“\(Self.captions[confidence] ?? "")”").foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            row("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder) }
            if !editing, let t = trail, !store.state(for: t.id).isDone {
                Toggle("Mark trail as done", isOn: $markDone).padding(.leading, 90)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Log") { submit() }.keyboardShortcut(.defaultAction).disabled(trail == nil)
            }
        }
        .padding(20).frame(width: 520)
        .onDisappear { store.logRunRequest = nil }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            content()
        }
    }

    private var picker: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let ts = store.catalog.trails.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VStack(spacing: 8) {
            TextField("Search trails", text: $query).textFieldStyle(.roundedBorder)
            List(ts, id: \.id) { t in
                Button { trailID = t.id; pickerShown = false } label: {
                    HStack {
                        BandSymbol(band: Band.of(store.effectiveRating(t))); Text(t.name); Spacer()
                        RatingPill(rating: store.effectiveRating(t), size: .caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.listStyle(.plain)
        }
        .padding(10).frame(width: 340, height: 360)
    }

    private func close() { store.logRunRequest = nil; dismiss() }

    private func submit() {
        guard let id = trailID else { return }
        if var e = request.existing {
            e.trailID = id; e.date = date; e.conditions = conditions; e.confidence = confidence; e.notes = notes
            store.updateRun(e)
        } else {
            let e = RunLogEntry(trailID: id, date: date, conditions: conditions, confidence: confidence, notes: notes)
            store.logRun(e, alsoMarkDone: markDone && !store.state(for: id).isDone)
        }
        close()
    }
}
