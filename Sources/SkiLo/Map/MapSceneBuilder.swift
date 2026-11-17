import Foundation

/// Catalog → static map scene (DESIGN §7). Pure.
enum MapSceneBuilder {
    static func scene(from catalog: TrailCatalog) -> MapScene {
        let trails = catalog.trails.map { t in
            TrailGeometry(id: t.id, name: t.name, polylines: t.geometry.filter { $0.count >= 2 },
                          midpoint: t.midpoint, bounds: t.bounds)
        }
        let lifts = catalog.lifts.filter { $0.polyline.count >= 2 }.map {
            LiftGeometry(id: $0.id, name: $0.name, kind: $0.kind, polyline: $0.polyline)
        }
        return MapScene(trails: trails,
                        connectors: catalog.connectors.map(\.polyline).filter { $0.count >= 2 },
                        lifts: lifts,
                        boundary: catalog.boundary.filter { $0.count >= 2 },
                        bounds: catalog.bounds)
    }
}
