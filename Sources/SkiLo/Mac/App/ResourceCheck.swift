import Foundation

/// Tiny helper to prove that the resource bundle resolves at runtime, both when run from
/// `.build/<config>/SkiLo` and from inside `build/SkiLo.app`.
enum ResourceCheck {
    /// URL of the bundled trails data, if present.
    static var trailsURL: URL? {
        Bundle.appResources.url(forResource: "trails", withExtension: "json", subdirectory: "Resources")
    }

    /// One-line description used by the placeholder UI and the Makefile's verify step.
    static var summary: String {
        let bundlePath = Bundle.appResources.bundlePath
        guard let url = trailsURL else {
            return "Bundle.appResources = \(bundlePath)\nResources/trails.json: MISSING"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        return "Bundle.appResources = \(bundlePath)\nResources/trails.json: \(size) bytes"
    }
}
