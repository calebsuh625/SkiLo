import Foundation
import AppKit

extension DevHooks {
    @MainActor
    static func apply(to store: AppStore) {
        let e = env
        guard e.keys.contains(where: { $0.hasPrefix("HT_") }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let s = e["HT_SECTION"], let section = SidebarSection(rawValue: s) { store.section = section }
            if let s = e["HT_BASE_STYLE"], let style = MapBaseStyle(rawValue: s) { store.mapBaseStyle = style }
            if let ids = e["HT_BUCKET"] { store.addToBucket(ids.split(separator: ",").map(String.init)) }
            if let id = e["HT_SELECT"] { store.select(id, showInspector: true) }
            if let c = e["HT_CAMERA"] {
                switch c {
                case "overview":      store.requestCamera(.overview)
                case "california":    store.requestCamera(.california)
                case "nevada":        store.requestCamera(.nevada)
                case "mottKillebrew": store.requestCamera(.mottKillebrew)
                case "fit":           if let id = e["HT_SELECT"] { store.requestCamera(.fit(id)) }
                default: break
                }
            }
            // HT_DIRECTIONS="<lodge or lift name>><trail id>", e.g. "Heavenly Village>t-ridge-run"
            if let d = e["HT_DIRECTIONS"] {
                let parts = d.split(separator: ">").map(String.init)
                let from = store.placeOptions.first { $0.title == parts.first }?.place
                let to: RoutePlace? = parts.count > 1 ? (store.trail(parts[1]) != nil ? .trail(parts[1]) : store.placeOptions.first { $0.title == parts[1] }?.place) : nil
                store.openDirections(to: to, from: from)
                if let r = e["HT_DIFFICULTY"], let v = RouteDifficulty(rawValue: r) { store.directions.difficulty = v; store.recomputeRoute() }
                if let leg = e["HT_FOCUS_LEG"].flatMap(Int.init), let l = store.directions.route?.legs.first(where: { $0.id == leg }) { store.focusMap(on: l) }
                if e["HT_FIT_ROUTE"] != nil, let r = store.directions.route { store.requestCamera(.bounds(GeoBounds.containing(r.coords))) }
            }
            // HT_FLY=<trail id> | route  (after HT_FLY_DELAY seconds, default 2)
            if let f = e["HT_FLY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(e["HT_FLY_DELAY"] ?? "") ?? 2)) {
                    if f == "route", let r = store.directions.route { store.flyThrough(route: r, title: "Route") } else { store.flyThrough(trail: f) }
                }
            }
            // HT_PLAN=top5 (Today's Pick) or id,id ; HT_PLAN_SHOW=1 draws it on the map
            if let p = e["HT_PLAN"] {
                store.loadForecast()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    store.addToPlan(p == "top5" ? store.todaysPicks.prefix(5).map(\.trailID) : p.split(separator: ",").map(String.init))
                    if e["HT_PLAN_SHOW"] != nil { store.showPlanOnMap() }
                }
            }
            if let ids = e["HT_MARK_DONE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    for id in ids.split(separator: ",") { store.markDone(String(id)) }
                }
            }
        }
    }
}
