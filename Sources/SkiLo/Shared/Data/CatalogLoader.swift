import Foundation

enum CatalogLoader {
    enum LoadError: Error, CustomStringConvertible {
        case missingResource
        var description: String { "trails.json not found in the resource bundle" }
    }
    static func resourceURL() -> URL? {
        if let u = DevHooks.catalogURL { return u }
        // Mac: inside the SwiftPM resource bundle's Resources/ folder. iPhone: at the app bundle root.
        return Bundle.appResources.url(forResource: "trails", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.appResources.url(forResource: "trails", withExtension: "json")
    }
    static func loadBundled() throws -> TrailCatalog {
        guard let url = resourceURL() else { throw LoadError.missingResource }
        return try load(from: url)
    }
    static func load(from url: URL) throws -> TrailCatalog { try load(data: Data(contentsOf: url)) }
    static func load(data: Data) throws -> TrailCatalog {
        var catalog = try JSONDecoder().decode(TrailCatalog.self, from: data)
        for i in catalog.trails.indices {
            catalog.trails[i].rating = DifficultyRating.breakdown(catalog.trails[i].ratingInput, catalog.trails[i].modifiers)
        }
        let problems = validate(catalog)
        if !problems.isEmpty { NSLog("CatalogLoader: %d problems: %@", problems.count, problems.prefix(10).joined(separator: "; ")) }
        return catalog
    }
    /// Non-fatal consistency checks (logged; tests assert empty on the real catalog).
    static func validate(_ c: TrailCatalog) -> [String] {
        var p: [String] = []
        if c.schemaVersion != 1 { p.append("schemaVersion \(c.schemaVersion)") }
        if c.ratingEngineVersion != DifficultyRating.version { p.append("ratingEngineVersion \(c.ratingEngineVersion) != \(DifficultyRating.version)") }
        let ids = c.trails.map(\.id)
        if Set(ids).count != ids.count { p.append("duplicate trail ids") }
        for t in c.trails where t.geometry.isEmpty || t.geometry.contains(where: { $0.count < 2 }) { p.append("\(t.id): bad geometry") }
        for t in c.trails { if let e = t.expectedRating, e != t.rating.total { p.append("\(t.id): rating \(t.rating.total) != expected \(e)") } }
        return p
    }
}
