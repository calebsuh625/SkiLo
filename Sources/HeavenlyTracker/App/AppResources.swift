import Foundation

extension Bundle {
    /// The app's resource bundle (the SwiftPM-generated `HeavenlyTracker_HeavenlyTracker.bundle`).
    ///
    /// USE THIS INSTEAD OF `Bundle.module`.
    ///
    /// Pure-SwiftPM's generated `Bundle.module` accessor only looks in two places:
    ///   1. `Bundle.main.bundleURL/<name>.bundle` — for a `.app` that is the *app root*, which
    ///      codesign rejects ("unsealed contents present in the bundle root"), and
    ///   2. the absolute `.build/...` path baked in at compile time, which disappears on
    ///      `make clean` or when the app is copied to another machine.
    /// It never checks `Contents/Resources`, where a well-formed app keeps resources (and where
    /// the Makefile puts the bundle). This accessor checks there first, then falls back to
    /// `Bundle.module` so `swift run` and `swift test` keep working from `.build/`.
    static let appResources: Bundle = {
        let name = "HeavenlyTracker_HeavenlyTracker.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }   // .app/Contents/Resources
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))                     // next to a bare executable
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }()
}
