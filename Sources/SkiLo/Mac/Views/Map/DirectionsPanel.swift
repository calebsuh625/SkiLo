import SwiftUI

/// Floating "A → B" panel over the map: choose a start and a destination (from lists or by
/// clicking the map), a difficulty limit, and get step-by-step directions.
struct DirectionsPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let d = store.directions
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Directions", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.headline)
                Spacer()
                Button { store.closeDirections() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close directions (Esc)")
            }

            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 6) {
                    endRow(.from, label: "From", color: .green)
                    endRow(.to, label: "To", color: .red)
                }
                Button { store.swapDirections() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .buttonStyle(.borderless).help("Swap start and destination")
                    .disabled(d.from == nil || d.to == nil)
            }

            Picker("Difficulty", selection: Binding(get: { store.directions.difficulty }, set: { store.directions.difficulty = $0; store.recomputeRoute() })) {
                ForEach(RouteDifficulty.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help(d.difficulty.detail)
            Text(difficultyCaption).font(.caption).foregroundStyle(.secondary)

            if d.picking != nil {
                Label(d.picking == .from ? "Click the map to set your start" : "Click a trail or spot on the map to go there",
                      systemImage: "hand.point.up.left.fill")
                    .font(.callout).foregroundStyle(.tint)
            }

            if let w = d.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = d.error {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let route = d.route {
                Divider()
                RouteSummary(route: route)
                HStack {
                    Button { store.flyThrough(route: route, title: "\(store.title(of: d.from)) → \(store.title(of: d.to, asDestination: true))") } label: {
                        Label("Fly Through", systemImage: "play.fill")
                    }
                    .help("Preview the route on the 3D map")
                    Spacer()
                }
                RouteSteps(route: route, focused: Binding(get: { store.directions.focusedLeg }, set: { store.directions.focusedLeg = $0 }))
                    .frame(maxHeight: 280)
            } else if d.from != nil && d.to == nil && d.error == nil {
                Text("Pick a destination: a lodge, a lift, or a trail to ski.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6, y: 2)
    }

    private var difficultyCaption: String {
        switch store.directions.difficulty {
        case .comfortable: "Trails up to \(RouteDifficulty.comfortable.maxRating(elo: store.elo) ?? 100) (your Elo is \(Elo.format(store.elo)))"
        case .stretch: "Trails up to \(RouteDifficulty.stretch.maxRating(elo: store.elo) ?? 100)"
        case .any: "Fastest way, any difficulty"
        }
    }

    private func endRow(_ end: DirectionsState.End, label: String, color: Color) -> some View {
        let place = end == .from ? store.directions.from : store.directions.to
        let picking = store.directions.picking == end
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            PlacePickerButton(title: store.title(of: place, asDestination: end == .to), prompt: label) { store.setDirections(end, $0) }
            Button {
                store.directions.picking = picking ? nil : end
            } label: { Image(systemName: picking ? "mappin.circle.fill" : "mappin.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(picking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(end == .from ? "Pick the start on the map" : "Pick the destination on the map")
        }
    }
}

/// "32 min · 4.1 mi · 2 lifts · 1,800 ft skied"
struct RouteSummary: View {
    @Environment(AppStore.self) private var store
    let route: Route
    var body: some View {
        let units = store.userData.profile.units
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.duration(route.seconds)).font(.title2.weight(.semibold).monospacedDigit())
            Text("· \(Format.length(route.lengthM, units)) · \(route.liftIDs.count) lift\(route.liftIDs.count == 1 ? "" : "s") · \(Format.vert(route.skiVerticalM, units)) skied")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }
}

/// Step list; hovering or clicking a step highlights it on the map.
struct RouteSteps: View {
    @Environment(AppStore.self) private var store
    let route: Route
    @Binding var focused: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(route.legs.filter { !$0.isMinor }) { leg in
                    row(leg)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(focused == leg.id ? Color.accentColor.opacity(0.18) : .clear))
                        .onHover { inside in focused = inside ? leg.id : (focused == leg.id ? nil : focused) }
                        .onTapGesture { store.focusMap(on: leg) }
                }
            }
        }
    }

    private func row(_ leg: RouteLeg) -> some View {
        HStack(spacing: 8) {
            icon(leg).frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(verb(leg) + store.legTitle(leg)).font(.callout).lineLimit(1)
                if case .ski(let id) = leg.kind, let t = store.trail(id) {
                    HStack(spacing: 4) {
                        BandSymbol(band: Band.of(store.effectiveRating(t))).font(.system(size: 8))
                        Text("\(store.effectiveRating(t)) · \(Format.distance(leg.lengthM, store.userData.profile.units))")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(RouteSummary.duration(leg.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }

    private func verb(_ leg: RouteLeg) -> String {
        switch leg.kind { case .ski: "Ski "; case .lift: "Ride "; case .traverse: "" }
    }

    @ViewBuilder private func icon(_ leg: RouteLeg) -> some View {
        switch leg.kind {
        case .ski(let id):
            RatingPill(rating: store.effectiveRating(id), size: .caption).fixedSize()
        case .lift(let id):
            Image(systemName: store.lift(id)?.kind == .gondola || store.lift(id)?.kind == .cableCar ? "cablecar.fill" : "cablecar")
                .foregroundStyle(.secondary)
        case .traverse:
            Image(systemName: "figure.walk").foregroundStyle(.secondary)
        }
    }
}

/// A button that opens a searchable list of lodges, lifts and trails.
struct PlacePickerButton: View {
    @Environment(AppStore.self) private var store
    let title: String
    let prompt: String
    let onPick: (RoutePlace) -> Void
    @State private var open = false
    @State private var search = ""

    var body: some View {
        Button { open = true } label: {
            HStack {
                Text(prompt).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(spacing: 0) {
                TextField("Search lodges, lifts, trails", text: $search)
                    .textFieldStyle(.roundedBorder).padding(8)
                List {
                    ForEach(PlaceOption.Group.allCases, id: \.self) { g in
                        let items = filtered.filter { $0.group == g }
                        if !items.isEmpty {
                            Section(g.rawValue) {
                                ForEach(items) { o in
                                    Button {
                                        onPick(o.place); open = false; search = ""
                                    } label: {
                                        HStack {
                                            if case .trail(let id) = o.place { RatingPill(rating: store.effectiveRating(id), size: .caption).fixedSize().frame(width: 34) }
                                            Text(o.title)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(width: 300, height: 420)
        }
    }

    private var filtered: [PlaceOption] {
        let all = store.placeOptions
        guard !search.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
}

/// Bottom-center control while a fly-through plays.
struct FlyThroughHUD: View {
    let model: MapScreenModel
    let onPause: (Bool) -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "airplane").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.flyTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Text(model.flyLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: model.flyProgress).frame(width: 240)
            }
            Button { model.flyPaused.toggle(); onPause(model.flyPaused) } label: {
                Image(systemName: model.flyPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless).help(model.flyPaused ? "Resume" : "Pause")
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless).help("Stop the fly-through (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6, y: 2)
    }
}
