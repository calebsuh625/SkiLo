import Foundation

enum MigrationError: Error, Equatable {
    /// The document was written by a newer app (schemaVersion > currentVersion).
    case newerSchema(Int)
    case notAnObject
}

enum Migrations {
    static let currentVersion = UserData.currentSchemaVersion
    typealias Step = @Sendable ([String: Any]) throws -> [String: Any]

    /// Registered v(n)→v(n+1) transforms, keyed by `n`. Empty while currentVersion == 1; a missing
    /// step is treated as the identity (new fields are optional and decoded with defaults).
    static var steps: [Int: Step] = [:]

    /// Applies v(n)→v(n+1) dictionary transforms until `target`. Throws on a newer version.
    static func run(json: [String: Any], from version: Int, to target: Int = Migrations.currentVersion,
                    steps: [Int: Step]? = nil) throws -> [String: Any] {
        if version > target { throw MigrationError.newerSchema(version) }
        let table = steps ?? Migrations.steps
        var out = json
        var v = max(version, 1)
        while v < target {
            if let step = table[v] { out = try step(out) }
            v += 1
            out["schemaVersion"] = v
        }
        return out
    }

    /// Parses raw JSON bytes, reads `schemaVersion` (missing → 1), migrates, returns the dictionary.
    static func migrate(data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MigrationError.notAnObject }
        let version = (obj["schemaVersion"] as? Int) ?? 1
        return try run(json: obj, from: version)
    }
}
