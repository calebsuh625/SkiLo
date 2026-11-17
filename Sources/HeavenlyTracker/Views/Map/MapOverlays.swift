import SwiftUI

/// SwiftUI chrome over the map (DESIGN §8.7): legend top-left, camera chips + OSM attribution
/// bottom-right, hover tooltip, offline banner top-center. The bottom-left 180×40 pt stays empty
/// for Apple's logo/legal link. The toast is RootView's job.
struct MapOverlays: View {
    @Environment(AppStore.self) private var store
    let engine: any MapEngine
    let viewSize: CGSize
    let model: MapScreenModel

    init(engine: any MapEngine, viewSize: CGSize, model: MapScreenModel) {
        self.engine = engine; self.viewSize = viewSize; self.model = model
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                if store.legendShown { MapLegend().transition(.opacity) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            VStack(alignment: .trailing, spacing: 10) {
                Spacer(minLength: 0)
                Text("Trails © OpenStreetMap contributors (ODbL)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                CameraChips()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(12)

            if model.offline && !model.offlineDismissed {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                        Text("Map imagery unavailable (offline?) — showing outline")
                        Button { model.offlineDismissed = true } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                    }
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }

            if model.tooltipVisible, let id = model.hoverID, let p = model.hoverPoint, let t = store.trail(id) {
                HoverTooltip(trail: t, rating: store.effectiveRating(id), units: store.userData.profile.units)
                    .fixedSize()
                    .position(tooltipPosition(p))
                    .allowsHitTesting(false)
            }
        }
        .overlay { if DevHooks.env["HT_PROJ_DEBUG"] != nil { ProjectionDebug(engine: engine) } }
        .animation(.easeOut(duration: 0.15), value: store.legendShown)
    }

    private func tooltipPosition(_ p: CGPoint) -> CGPoint {
        // Above-right of the cursor, kept inside the view.
        let w: CGFloat = 220, h: CGFloat = 48
        let x = min(max(p.x + 16 + w / 2, w / 2 + 4), max(viewSize.width - w / 2 - 4, w / 2))
        let y = p.y - 16 - h / 2 < h / 2 ? p.y + 20 + h / 2 : p.y - 16 - h / 2
        return CGPoint(x: x, y: y)
    }
}

private struct HoverTooltip: View {
    let trail: Trail
    let rating: Int
    let units: Units
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(trail.name).font(.callout.weight(.semibold))
                Text("·").foregroundStyle(.secondary)
                BandSymbol(band: Band.of(rating)).font(.caption)
                Text("\(rating)").font(.callout.monospacedDigit().weight(.semibold))
            }
            Text("\(Format.length(trail.stats.lengthM, units)) · \(Format.vert(trail.stats.verticalDropM, units)) · \(Format.grade(trail.stats.avgGradePct)) avg")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
    }
}

private struct CameraChips: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 0) {
            chip("Overview", .overview, help: "Whole resort (⌘0)")
            divider
            chip("CA", .california, help: "California side (⌥⌘1)")
            divider
            chip("NV", .nevada, help: "Nevada side (⌥⌘2)")
            divider
            chip("Mott/Killebrew", .mottKillebrew, help: "Mott & Killebrew canyons (⌥⌘3)")
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
    private var divider: some View { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 14) }
    private func chip(_ title: String, _ preset: CameraPreset, help: String) -> some View {
        Button { store.requestCamera(preset) } label: {
            Text(title).font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Legend (UX §2.3): continuous ramp 1…100 with band ticks, status key, lift/boundary key.
private struct MapLegend: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Difficulty").font(.caption.weight(.semibold))
                Spacer()
                Button { store.legendShown = false } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide legend (⇧⌘L)")
            }
            RampBar().frame(height: 10)
            HStack(spacing: 0) {
                ForEach(Band.allCases, id: \.self) { b in
                    HStack(spacing: 3) {
                        BandSymbol(band: b).font(.system(size: 8))
                        Text("\(b.range.lowerBound)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            statusRow(color: Ramp.color(for: 60), casing: TrailStyleBuilder.casingLight, glyph: nil, title: "Not done")
            statusRow(color: Ramp.doneColor(for: 60), casing: TrailStyleBuilder.casingLight, glyph: ("checkmark", Ramp.doneGreen, .white), title: "Done", opacity: 0.55)
            statusRow(color: Ramp.color(for: 60), casing: Ramp.bucketYellow, glyph: ("star.fill", RGBA(hex: "#1C1C1E"), Ramp.bucketYellow), title: "Bucket list")
            Divider()
            HStack(spacing: 6) {
                DashedLine(color: Ramp.liftGray.color, dash: [6, 4], width: 2).frame(width: 28, height: 4)
                Text("Lift").font(.caption)
                Spacer().frame(width: 10)
                DashedLine(color: .primary.opacity(0.7), dash: [4, 4], width: 1).frame(width: 28, height: 4)
                Text("Boundary").font(.caption)
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
    }

    private func statusRow(color: RGBA, casing: RGBA, glyph: (String, RGBA, RGBA)?, title: String, opacity: Double = 1) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Capsule().fill(casing.color).frame(width: 28, height: 6)
                Capsule().fill(color.color).frame(width: 26, height: 3)
            }
            .opacity(opacity)
            .frame(width: 28)
            if let (name, bg, fg) = glyph {
                Image(systemName: name).font(.system(size: 7, weight: .heavy)).foregroundStyle(fg.color)
                    .frame(width: 13, height: 13).background(Circle().fill(bg.color))
            } else {
                Color.clear.frame(width: 13, height: 13)
            }
            Text(title).font(.caption)
        }
    }
}

private struct RampBar: View {
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                LinearGradient(stops: Ramp.stops.map { .init(color: $0.color.color, location: Double($0.rating - 1) / 99) },
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                ForEach([25, 50, 75], id: \.self) { r in
                    Rectangle().fill(.white.opacity(0.9)).frame(width: 1.5, height: g.size.height + 4)
                        .offset(x: g.size.width * CGFloat(r - 1) / 99 - 0.75)
                }
            }
        }
    }
}

private struct DashedLine: View {
    let color: Color
    let dash: [CGFloat]
    let width: CGFloat
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2)) }
                .stroke(color, style: StrokeStyle(lineWidth: width, dash: dash))
        }
    }
}

/// `HT_PROJ_DEBUG=1`: draws `engine.project()` of the selected trail's vertices (cyan dots), to
/// compare MapKit's projection with where it actually drew the polyline.
private struct ProjectionDebug: View {
    @Environment(AppStore.self) private var store
    let engine: any MapEngine
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Canvas { ctx, _ in
                guard let id = store.selection, let t = store.trail(id) else { return }
                for c in t.allCoordinates {
                    if let p = engine.project(c) { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.cyan)) }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
