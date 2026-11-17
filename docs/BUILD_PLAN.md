# SkiLo — Build Plan for Parallel Implementation

Status: v1, 2026-11-01. Companion to `docs/DESIGN.md` (architecture, schema, decisions) and
`docs/UX_SPEC.md` (screens, behaviour). When this plan and the UX spec disagree on *interfaces* or
*file paths*, this plan wins; for *behaviour* of a screen, the UX spec wins unless DESIGN §6 says otherwise.

Seven packages. **WP0 (scaffold) lands first and alone.** WP1–WP5 then run in parallel with no
overlapping files. **WP6 (integration) runs last.** V1 scope = the P0 list in UX_SPEC §9.1.

| # | Package | Owner label | Creates / edits (summary) | Depends on |
|---|---|---|---|---|
| 0 | Scaffold | `wp0-scaffold` | Package.swift (verify), `App/*`, `Models/*`, `Data/*`, `Rating/RatingTypes.swift`, `Map/MapEngine.swift`, `Store/Toast.swift`, `Progression/ProgressionTypes.swift`, every other file as a compiling **stub**, placeholder catalog, `Tests/TestSupport.swift`, `Tests/SmokeTests.swift` | — |
| 1 | Data & Rating | `wp1-data-rating` | `tools/build_catalog.py`, `data/overrides/trail_overrides.json`, `Resources/trails.json`, `Makefile` (sync-data), `Rating/DifficultyRating.swift`, `Tests/{RatingTests,CatalogTests}.swift` | WP0 |
| 2 | Core: store, persistence, style | `wp2-core` | `Store/AppStore.swift`, `Persistence/*`, `Style/*`, `Tests/{StoreTests,PersistenceTests,StyleTests}.swift` | WP0 |
| 3 | Map engine & screen | `wp3-map` | `Map/*` except `MapEngine.swift`, `Views/Map/*`, `Tests/{PickingTests,CameraPresetsTests}.swift` | WP0 |
| 4 | Screens A: shell, trails, inspector, settings, onboarding, menus | `wp4-screens-a` | `Views/Shell/*`, `Views/Trails/*`, `Views/Inspector/*`, `Views/Settings/*`, `Views/Onboarding/*`, `Views/Shared/*` (polish), `App/AppCommands.swift`, `Tests/FilterTests.swift` | WP0 |
| 5 | Screens B + progression: bucket, log, progress, engines | `wp5-screens-b` | `Progression/{DefaultProgressionEngine,Milestones}.swift`, `Views/Bucket/*`, `Views/Log/*`, `Views/Progress/*`, `Tests/{ProgressionTests,MilestoneTests}.swift` | WP0 |
| 6 | Integration | `wp6-integration` | may edit any file to resolve conflicts (log every edit), `README.md`, `docs/ACCEPTANCE.md`, `assets/AppIcon.icns` (optional) | WP1–WP5 |

---

## 0. Ground rules for every package

### 0.1 Toolchain (verified by the build agent; do not deviate)

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools      # mandatory in every shell
cd <your tree>
swift build 2>&1 | tail -20                                    # debug, ~35 s cold / 3 s incremental
swift build -c release                                          # release
tools/run_tests.sh                                              # ALL tests (swift-testing) — see warning below
tools/run_tests.sh --filter Rating                              # suites/tests matching a regex
tools/build_app.sh            # release .app → build/SkiLo.app (ad-hoc signed)
tools/build_app.sh verify     # launches the .app headless, screenshots to build/verify.png, exits
```

- **`swift test` is a silent no-op on this machine.** Under CLT it builds the test bundle and then
  runs nothing (exit 0, no test output; verified on 2026-11-01 on both this package and a scratch
  copy: `swift test -v` shows only `dsymutil`, no runner, because CLT has no `xctest` host and
  SwiftPM does not report it). The build agent's "2 tests pass" claim was not reproducible. Always
  use `tools/run_tests.sh` (builds `tools/testhost`, a 20-line dlopen host that calls swift-testing's
  `__swiftPMEntryPoint()`; verified: 4/4 scaffold tests reported, `--filter` honoured, a deliberately
  failing test exits 1). A green run prints `✔ Test run with N tests in M suites passed`; if you do
  not see that line, nothing ran.
- `import Testing` only (`@Suite`, `@Test`, `#expect`, `#require`). **`import XCTest` does not compile** under CLT.
- Never run `xcodebuild`, `/usr/bin/make`, or anything needing sudo. Use `tools/build_app.sh <target>`.
- Language mode stays Swift 5 (`.swiftLanguageMode(.v5)`); concurrency diagnostics are warnings. Do
  not add `-warnings-as-errors`.
- Resources: `Bundle.appResources.url(forResource:withExtension:subdirectory: "Resources")`, never `Bundle.module`.
- No new SwiftPM dependencies. Swift Charts, MapKit, AppKit, SwiftUI, Observation only.
- Do **not** `git commit`.

### 0.2 File ownership

- Every file listed under a package is created or edited **only** by that package after WP0 lands.
  WP0 creates stub versions of many files that later packages *replace in full*; from then on the
  later package owns them. A package may add new files only inside its own folders.
- Never edit `Map/MapEngine.swift`, `Models/*`, `Rating/RatingTypes.swift`,
  `Progression/ProgressionTypes.swift`, `Store/Toast.swift`, `Data/CatalogLoader.swift`,
  `Tests/TestSupport.swift`, `tools/run_tests.sh`, `tools/testhost/main.swift` after WP0: those are the shared contract. If a contract change is
  unavoidable, stop and report it to the orchestrator; do not change it unilaterally.
- Each package also owns exactly the test files listed for it.

### 0.3 Working-tree protocol (parallel agents, one machine)

A half-written file from another agent breaks everybody's `swift build`. Therefore each of WP1–WP5:

1. Copies the tree once WP0 has landed:
   `rsync -a --exclude .build --exclude build --exclude spikes --exclude data/dem/tiles /Users/calebsuh/Projects/SkiLo/ /private/tmp/claude-501/-Users-calebsuh/810bede8-95e3-4752-88a3-c504cfe6ddb2/scratchpad/wpN/`
2. Works and builds in that copy (`swift build`, `tools/run_tests.sh --filter …`, screenshots).
3. When green, copies **only its owned files** back into `/Users/calebsuh/Projects/SkiLo/`
   (`cp` per file or `rsync` with an explicit file list; never a whole-tree rsync back).
4. Reports the exact list of files delivered.

If the orchestrator runs packages sequentially instead, agents may work in-tree but must use a
private scratch path for builds: `swift build --scratch-path /private/tmp/.../scratchpad/build-wpN`.

### 0.4 Headless verification (no human, no foreground sleep)

Use the dev hooks from DESIGN §11 and the existing self-capture. Example for the map with the
bundled catalog, scripted state, isolated user data:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build -c release
OUT=/private/tmp/claude-501/-Users-calebsuh/810bede8-95e3-4752-88a3-c504cfe6ddb2/scratchpad/shots
mkdir -p $OUT/userdata
HT_USERDATA_DIR=$OUT/userdata HT_SCREENSHOT=$OUT/map_ca.png HT_SCREENSHOT_DELAY=10 \
HT_SECTION=map HT_CAMERA=california HT_SELECT=t-gunbarrel \
timeout 60 .build/arm64-apple-macosx/release/SkiLo ; echo "exit $?"
```
Run it with `run_in_background` (or `&` + `timeout`), then **Read the PNG** and describe honestly
what rendered. `screencapture -l` needs Screen Recording permission for the terminal; it worked for
the build agent and all three spikes.

### 0.5 Definition of done (every package)

- `swift build` is warning-tolerant but **error-free** in the package's copy with WP0's stubs for
  everyone else's code.
- The package's tests pass: `tools/run_tests.sh --filter <Suite>` (never bare `swift test`, see §0.1).
- The final report lists delivered files (absolute paths), commands run with results, screenshots
  viewed, and anything not verified. Never claim something works unless you ran it.

---

## WP0 — Scaffold (`wp0-scaffold`, sequential, lands first)

Goal: the package compiles, tests pass, the app launches to a window, and **every type name and
signature the other packages compile against exists**. Stubs return sensible defaults (never
`fatalError`), so the app stays runnable at every stage.

### WP0.1 File operations

1. Move existing files: `Sources/SkiLo/{SkiLoApp,AppResources,ResourceCheck,SelfCapture}.swift`
   → `Sources/SkiLo/App/`. Delete `ContentView.swift`. Split `AppDelegate` out of
   `SkiLoApp.swift` into `App/AppDelegate.swift` (same code, plus `applicationShouldTerminate`
   is **not** needed — the store flushes on `willTerminateNotification`).
2. `Package.swift`: unchanged (verify it still builds after the moves; SwiftPM picks up subfolders).
   `Makefile`: change only the `test` target so that it reads
   ```make
   test:
   	tools/run_tests.sh
   ```
   (WP1 later edits only `sync-data`). `tools/testhost/main.swift` and `tools/run_tests.sh` already
   exist (architect-verified); do not modify them.
3. Create every file in the tree below. "FULL" = complete implementation by WP0 (never edited later
   unless the owner column says otherwise); "STUB → WPn" = compiling placeholder replaced by WPn.

```
App/SkiLoApp.swift      FULL (owner WP0)
App/AppDelegate.swift             FULL (WP0)
App/AppResources.swift            FULL (moved, WP0)
App/ResourceCheck.swift           FULL (moved, WP0)
App/SelfCapture.swift             FULL (moved; default HT_SCREENSHOT_DELAY stays 1.5 s, WP0)
App/DevHooks.swift                FULL (WP0)
App/AppCommands.swift             STUB → WP4
Models/GeoCoordinate.swift        FULL
Models/Catalog.swift              FULL
Models/UserData.swift             FULL
Models/TrailFilter.swift          FULL
Models/RGBA.swift                 FULL
Data/CatalogLoader.swift          FULL
Rating/RatingTypes.swift          FULL
Rating/DifficultyRating.swift     STUB → WP1
Style/Ramp.swift                  STUB → WP2
Style/TrailStyleBuilder.swift     STUB → WP2
Progression/ProgressionTypes.swift        FULL
Progression/DefaultProgressionEngine.swift STUB → WP5
Progression/Milestones.swift              STUB → WP5
Persistence/UserDataStore.swift   STUB → WP2
Persistence/Migrations.swift      STUB → WP2
Persistence/ExportImport.swift    STUB → WP2
Store/AppStore.swift              STUB (full interface, naive bodies) → WP2
Store/Toast.swift                 FULL
Map/MapEngine.swift               FULL (DESIGN §7 verbatim)
Map/MapSceneBuilder.swift         STUB → WP3
Map/CameraPresets.swift           STUB → WP3
Map/Picking.swift                 STUB → WP3
Map/MapKitEngine.swift            STUB → WP3
Map/MapHostView.swift             FULL (owner WP3 may edit)
Views/Map/MapScreen.swift         STUB → WP3
Views/Map/MapOverlays.swift       STUB → WP3
Views/Shell/RootView.swift        STUB → WP4
Views/Shell/SidebarView.swift     STUB → WP4
Views/Shell/MiniProgressCard.swift STUB → WP4
Views/Trails/TrailsScreen.swift   STUB → WP4
Views/Inspector/TrailInspector.swift STUB → WP4
Views/Inspector/ElevationProfileChart.swift STUB → WP4
Views/Inspector/RatingBreakdownView.swift   STUB → WP4
Views/Inspector/OverridePopover.swift       STUB → WP4
Views/Settings/SettingsView.swift STUB → WP4
Views/Onboarding/OnboardingSheet.swift STUB → WP4
Views/Bucket/BucketScreen.swift   STUB → WP5
Views/Bucket/AddTrailPopover.swift STUB → WP5
Views/Log/LogScreen.swift         STUB → WP5
Views/Log/LogRunSheet.swift       STUB → WP5
Views/Log/EditDaySheet.swift      STUB → WP5
Views/Progress/ProgressScreen.swift STUB → WP5
Views/Shared/RatingPill.swift     FULL minimal (owner WP4 may polish)
Views/Shared/BandSymbol.swift     FULL minimal (WP4)
Views/Shared/StatusGlyph.swift    FULL minimal (WP4)
Views/Shared/ReadinessChip.swift  FULL minimal (WP4)
Views/Shared/Format.swift         FULL (WP4)
Views/Shared/ToastView.swift      STUB → WP4
Resources/trails.json             placeholder in the FINAL schema (2 trails) → WP1 replaces
Tests/SkiLoTests/TestSupport.swift  FULL
Tests/SkiLoTests/SmokeTests.swift   FULL (rewritten)
```

### WP0.2 Shared contract — verbatim Swift

The code below is normative. Copy it exactly; fix only compile errors and report them.
The architect extracted every block below into a scratch package together with the view stubs of
§"View stubs"/"Shared views" and verified on 2026-11-01: `swift build` 0 errors (debug and release),
`tools/run_tests.sh` → 4/4 SmokeTests pass, and the app launched headless with `HT_SECTION=map
HT_SELECT=t-gunbarrel HT_MARK_DONE=t-gunbarrel` and screenshotted (stub map placeholder + overlay
text). That verified tree is at
`/private/tmp/claude-501/-Users-calebsuh/810bede8-95e3-4752-88a3-c504cfe6ddb2/scratchpad/contractcheck/`
(scratch; may vanish) — if it still exists, copy its `Sources/` and `Tests/` as the starting point
and then do WP0.1's moves/deletes; this document remains the authority if they differ.

#### `App/SkiLoApp.swift`
```swift
import SwiftUI
import AppKit

@main
@MainActor
struct SkiLoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.bootstrap()

    var body: some Scene {
        WindowGroup("SkiLo") {
            RootView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { DevHooks.apply(to: store) }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(store: store) }

        Settings {
            SettingsView().environment(store)
        }
    }
}
```

#### `App/AppDelegate.swift`
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)          // bare executables have no Info.plist
        NSApp.activate(ignoringOtherApps: true)
        SelfCapture.scheduleIfRequested()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

#### `App/DevHooks.swift`
```swift
import Foundation
import AppKit

/// Scripted-state hooks (DESIGN §11). Only active when an HT_* variable is set.
enum DevHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var isScripted: Bool { env["HT_SCREENSHOT"] != nil }
    static var skipOnboarding: Bool { isScripted || env["HT_SKIP_ONBOARDING"] == "1" }
    static var userDataDirectory: URL? { env["HT_USERDATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var catalogURL: URL? { env["HT_CATALOG"].map { URL(fileURLWithPath: $0) } }

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
            if let ids = e["HT_MARK_DONE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    for id in ids.split(separator: ",") { store.markDone(String(id)) }
                }
            }
        }
    }
}
```

#### `Models/GeoCoordinate.swift`
```swift
import Foundation

/// WGS-84 point. JSON form is a GeoJSON-ordered array: [lon, lat] or [lon, lat, ele_m].
struct GeoCoordinate: Hashable, Sendable, Codable {
    var lat: Double
    var lon: Double
    var ele: Double?

    init(lat: Double, lon: Double, ele: Double? = nil) { self.lat = lat; self.lon = lon; self.ele = ele }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lon = try c.decode(Double.self)
        let lat = try c.decode(Double.self)
        var ele: Double? = nil
        if !c.isAtEnd { ele = try c.decodeIfPresent(Double.self) }
        self.init(lat: lat, lon: lon, ele: ele)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lon); try c.encode(lat)
        if let ele { try c.encode(ele) }
    }

    /// Haversine distance in metres.
    func distance(to o: GeoCoordinate) -> Double {
        let r = 6_371_008.8, d = Double.pi / 180
        let dLat = (o.lat - lat) * d, dLon = (o.lon - lon) * d
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat * d) * cos(o.lat * d) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

struct GeoBounds: Hashable, Sendable, Codable {
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double

    var center: GeoCoordinate { GeoCoordinate(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2) }
    var widthM: Double { (maxLon - minLon) * 111_320 * cos(center.lat * .pi / 180) }
    var heightM: Double { (maxLat - minLat) * 110_574 }
    var diagonalM: Double { (widthM * widthM + heightM * heightM).squareRoot() }

    static func containing(_ coords: [GeoCoordinate]) -> GeoBounds {
        guard let f = coords.first else { return GeoBounds(minLat: 0, minLon: 0, maxLat: 0, maxLon: 0) }
        var b = GeoBounds(minLat: f.lat, minLon: f.lon, maxLat: f.lat, maxLon: f.lon)
        for c in coords {
            b.minLat = min(b.minLat, c.lat); b.maxLat = max(b.maxLat, c.lat)
            b.minLon = min(b.minLon, c.lon); b.maxLon = max(b.maxLon, c.lon)
        }
        return b
    }
    func padded(byMetres m: Double) -> GeoBounds {
        let dLat = m / 110_574, dLon = m / (111_320 * cos(center.lat * .pi / 180))
        return GeoBounds(minLat: minLat - dLat, minLon: minLon - dLon, maxLat: maxLat + dLat, maxLon: maxLon + dLon)
    }
}
```

#### `Models/Catalog.swift`
```swift
import Foundation

struct TrailCatalog: Codable, Sendable {
    var schemaVersion: Int
    var resort: String
    var generatedAt: String
    var source: Provenance
    var ratingEngineVersion: String
    var bounds: GeoBounds
    var trails: [Trail]
    var connectors: [Connector]
    var lifts: [Lift]
    var boundary: [[GeoCoordinate]]

    var trailsByID: [Trail.ID: Trail] { Dictionary(uniqueKeysWithValues: trails.map { ($0.id, $0) }) }
}

struct Provenance: Codable, Hashable, Sendable {
    var osm: String
    var license: String
    var osmTimestamp: String
    var elevation: String
    var pipeline: String
    var modifiersVersion: String
}

enum Area: String, Codable, CaseIterable, Hashable, Sendable {
    case california = "CA", nevada = "NV"
    var title: String { self == .california ? "California" : "Nevada" }
}

enum SubArea: String, Codable, CaseIterable, Hashable, Sendable {
    case gunbarrelFace, skyCanyonPowderbowl, tamarackTop
    case dipperComet, olympicStagecoach, boulderGalaxyNorthBowl
    case mottCanyon, killebrewCanyon
    case other
    var title: String {
        switch self {
        case .gunbarrelFace: "Gunbarrel / Face"
        case .skyCanyonPowderbowl: "Sky / Canyon / Powderbowl"
        case .tamarackTop: "Tamarack / Top"
        case .dipperComet: "Dipper / Comet"
        case .olympicStagecoach: "Olympic / Stagecoach"
        case .boulderGalaxyNorthBowl: "Boulder / Galaxy / North Bowl"
        case .mottCanyon: "Mott Canyon"
        case .killebrewCanyon: "Killebrew Canyon"
        case .other: "Other"
        }
    }
}

enum OSMDifficulty: String, Codable, CaseIterable, Hashable, Sendable {
    case easy, intermediate, advanced, expert, unknown
    var band: Band? {
        switch self {
        case .easy: .green
        case .intermediate: .blue
        case .advanced: .black
        case .expert: .doubleBlack
        case .unknown: nil
        }
    }
}

enum Grooming: String, Codable, CaseIterable, Hashable, Sendable {
    case groomed, moguls, backcountry, unknown
    var title: String {
        switch self {
        case .groomed: "Groomed"
        case .moguls: "Moguls"
        case .backcountry: "Backcountry"
        case .unknown: "—"
        }
    }
}

/// Derived from the effective rating; never stored. UX_SPEC §8.1 cuts.
enum Band: Int, Codable, CaseIterable, Hashable, Sendable {
    case green = 0, blue, black, doubleBlack
    static func of(_ rating: Int) -> Band { rating < 25 ? .green : rating < 50 ? .blue : rating < 75 ? .black : .doubleBlack }
    var title: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .doubleBlack: "Double Black"
        }
    }
    var symbolName: String {
        switch self {
        case .green: "circle.fill"
        case .blue: "square.fill"
        case .black, .doubleBlack: "diamond.fill"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .green: 1...24
        case .blue: 25...49
        case .black: 50...74
        case .doubleBlack: 75...100
        }
    }
}

enum LiftKind: String, Codable, Hashable, Sendable {
    case chairLift = "chair_lift", gondola, cableCar = "cable_car", magicCarpet = "magic_carpet", ropeTow = "rope_tow"
}

struct TrailStats: Codable, Hashable, Sendable {
    var lengthM: Double
    var verticalDropM: Double
    var topElevM: Double
    var bottomElevM: Double
    var avgGradePct: Double
    var maxGradePct: Double          // steepest 50 m window
    var sustainedGradePct: Double    // steepest 150 m window
    var p90GradePct: Double
    var terrainSlopePctP90: Double
    var aspectDeg: Double
    var maxSegmentLengthM: Double
    var segmentsRelation: String     // single | chained | branches
}

/// JSON form: [distanceM, elevationM, gradePct]
struct ProfileSample: Hashable, Sendable, Codable {
    var distanceM: Double
    var elevationM: Double
    var gradePct: Double
    init(distanceM: Double, elevationM: Double, gradePct: Double) {
        self.distanceM = distanceM; self.elevationM = elevationM; self.gradePct = gradePct
    }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        distanceM = try c.decode(Double.self); elevationM = try c.decode(Double.self); gradePct = try c.decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(distanceM); try c.encode(elevationM); try c.encode(gradePct)
    }
}

struct Trail: Codable, Identifiable, Hashable, Sendable {
    typealias ID = String            // "t-" + slug(name), e.g. "t-gunbarrel", "t-the-y", "t-100-saddle"
    let id: ID
    let name: String
    let pipelineID: String
    let osmWayIDs: [Int]
    let area: Area
    let areaConfidence: String
    let subArea: SubArea
    let liftName: String?
    let liftAtBottomName: String?
    let osmDifficulty: OSMDifficulty
    let grooming: Grooming
    let gladed: Bool
    let oneway: Bool
    let geometry: [[GeoCoordinate]]  // one polyline per OSM way, top → bottom
    let midpoint: GeoCoordinate
    let top: GeoCoordinate
    let bottom: GeoCoordinate
    let stats: TrailStats
    let profile: [ProfileSample]
    let modifiers: CuratedModifiers
    let expectedRating: Int?
    /// Filled by CatalogLoader (not in JSON).
    var rating: RatingBreakdown = .unrated

    private enum CodingKeys: String, CodingKey {
        case id, name, pipelineID, osmWayIDs, area, areaConfidence, subArea, liftName, liftAtBottomName
        case osmDifficulty, grooming, gladed, oneway, geometry, midpoint, top, bottom, stats, profile, modifiers, expectedRating
    }

    var ratingInput: RatingInput {
        RatingInput(sustainedGradePct: stats.sustainedGradePct, maxGradePct: stats.maxGradePct,
                    verticalDropM: stats.verticalDropM, osmDifficulty: osmDifficulty,
                    grooming: grooming, gladed: gladed)
    }
    var allCoordinates: [GeoCoordinate] { geometry.flatMap { $0 } }
    var bounds: GeoBounds { GeoBounds.containing(allCoordinates) }
}

struct Connector: Codable, Identifiable, Hashable, Sendable {
    let id: String                   // "u-" + osm way id
    let osmWayID: Int
    let name: String
    let nearestTrail: Trail.ID?
    let osmDifficulty: OSMDifficulty
    let polyline: [GeoCoordinate]
}

struct Lift: Codable, Identifiable, Hashable, Sendable {
    typealias ID = String            // "l-" + osm way id
    let id: ID
    let osmWayID: Int
    let name: String
    let kind: LiftKind
    let area: Area
    let polyline: [GeoCoordinate]    // bottom → top
    let bottomElevM: Double
    let topElevM: Double
    let verticalM: Double
    let lengthM: Double
}
```

#### `Models/UserData.swift` (UX_SPEC §7.2; every type decodes missing keys to its default)
```swift
import Foundation

enum Units: String, Codable, CaseIterable, Sendable { case imperial, metric }
enum TrailStatus: String, Codable, CaseIterable, Hashable, Sendable { case notDone, bucket, done }

struct UserTrailState: Codable, Equatable, Hashable, Sendable {
    var status: TrailStatus = .notDone
    var bucketedAt: Date? = nil          // kept after .done → "crossed off"
    var firstDoneDate: Date? = nil
    var lastDoneDate: Date? = nil
    var timesSkied: Int = 0
    var backfilled: Bool = false
    var ratingOverride: Int? = nil       // 1…100
    var ratingOverrideNote: String? = nil
    var notes: String = ""
    var photoFilenames: [String] = []

    init() {}
    var isEmpty: Bool { self == UserTrailState() }
    var isDone: Bool { status == .done }

    private enum CodingKeys: String, CodingKey { case status, bucketedAt, firstDoneDate, lastDoneDate, timesSkied, backfilled, ratingOverride, ratingOverrideNote, notes, photoFilenames }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(TrailStatus.self, forKey: .status) ?? .notDone
        bucketedAt = try c.decodeIfPresent(Date.self, forKey: .bucketedAt)
        firstDoneDate = try c.decodeIfPresent(Date.self, forKey: .firstDoneDate)
        lastDoneDate = try c.decodeIfPresent(Date.self, forKey: .lastDoneDate)
        timesSkied = try c.decodeIfPresent(Int.self, forKey: .timesSkied) ?? 0
        backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
        ratingOverride = try c.decodeIfPresent(Int.self, forKey: .ratingOverride)
        ratingOverrideNote = try c.decodeIfPresent(String.self, forKey: .ratingOverrideNote)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        photoFilenames = try c.decodeIfPresent([String].self, forKey: .photoFilenames) ?? []
    }
}

enum Conditions: String, Codable, CaseIterable, Hashable, Sendable {
    case groomed, packedPowder, powder, chopped, firm, slush, moguls, variable
    var multiplier: Double {
        switch self {
        case .groomed, .packedPowder: 1.00
        case .powder: 0.95
        case .chopped: 1.10
        case .firm: 1.15
        case .slush: 1.05
        case .moguls: 1.10
        case .variable: 1.10
        }
    }
    var label: String {
        switch self {
        case .groomed: "Groomed"
        case .packedPowder: "Packed"
        case .powder: "Powder"
        case .chopped: "Chopped"
        case .firm: "Firm/icy"
        case .slush: "Slush"
        case .moguls: "Bumped up"
        case .variable: "Variable"
        }
    }
}

struct RunLogEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var trailID: Trail.ID
    var date: Date
    var conditions: Conditions = .groomed
    var confidence: Int = 3            // 1…5
    var notes: String = ""
    var isFirstTime: Bool = false
    var dayKey: String { SkiDay.key(for: date) }

    init(id: UUID = UUID(), trailID: Trail.ID, date: Date, conditions: Conditions = .groomed, confidence: Int = 3, notes: String = "", isFirstTime: Bool = false) {
        self.id = id; self.trailID = trailID; self.date = date; self.conditions = conditions
        self.confidence = confidence; self.notes = notes; self.isFirstTime = isFirstTime
    }
    private enum CodingKeys: String, CodingKey { case id, trailID, date, conditions, confidence, notes, isFirstTime }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trailID = try c.decode(Trail.ID.self, forKey: .trailID)
        date = try c.decode(Date.self, forKey: .date)
        conditions = try c.decodeIfPresent(Conditions.self, forKey: .conditions) ?? .groomed
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 3
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFirstTime = try c.decodeIfPresent(Bool.self, forKey: .isFirstTime) ?? false
    }
}

struct SkiDayMeta: Codable, Equatable, Hashable, Sendable {
    var title: String = ""
    var conditions: Conditions? = nil
    var notes: String = ""
    init(title: String = "", conditions: Conditions? = nil, notes: String = "") { self.title = title; self.conditions = conditions; self.notes = notes }
    private enum CodingKeys: String, CodingKey { case title, conditions, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        conditions = try c.decodeIfPresent(Conditions.self, forKey: .conditions)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct SkillPoint: Codable, Equatable, Hashable, Sendable {
    var date: Date
    var value: Double
    var low: Double
    var high: Double
    var runCount: Int
}

struct UserProfile: Codable, Equatable, Hashable, Sendable {
    var selfAssessedStart: Int = 30
    var startDate: Date = Date()
    var units: Units = .imperial
    var onboardingDone: Bool = false
    var skillHistory: [SkillPoint] = []
    var unlockedMilestones: [String: Date] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case selfAssessedStart, startDate, units, onboardingDone, skillHistory, unlockedMilestones }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selfAssessedStart = try c.decodeIfPresent(Int.self, forKey: .selfAssessedStart) ?? 30
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
        units = try c.decodeIfPresent(Units.self, forKey: .units) ?? .imperial
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        skillHistory = try c.decodeIfPresent([SkillPoint].self, forKey: .skillHistory) ?? []
        unlockedMilestones = try c.decodeIfPresent([String: Date].self, forKey: .unlockedMilestones) ?? [:]
    }
}

struct UserData: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    var schemaVersion: Int = UserData.currentSchemaVersion
    var appVersion: String = UserData.appVersion
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var profile: UserProfile = UserProfile()
    var trailStates: [Trail.ID: UserTrailState] = [:]
    var bucketOrder: [Trail.ID] = []
    var runLog: [RunLogEntry] = []
    var skiDays: [String: SkiDayMeta] = [:]

    init() {}
    static func fresh() -> UserData { UserData() }
    func state(for id: Trail.ID) -> UserTrailState { trailStates[id] ?? UserTrailState() }

    private enum CodingKeys: String, CodingKey { case schemaVersion, appVersion, createdAt, updatedAt, profile, trailStates, bucketOrder, runLog, skiDays }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        profile = try c.decodeIfPresent(UserProfile.self, forKey: .profile) ?? UserProfile()
        trailStates = try c.decodeIfPresent([Trail.ID: UserTrailState].self, forKey: .trailStates) ?? [:]
        bucketOrder = try c.decodeIfPresent([Trail.ID].self, forKey: .bucketOrder) ?? []
        runLog = try c.decodeIfPresent([RunLogEntry].self, forKey: .runLog) ?? []
        skiDays = try c.decodeIfPresent([String: SkiDayMeta].self, forKey: .skiDays) ?? [:]
    }
}

/// Derived grouping of the log by local calendar day (newest first).
struct SkiDay: Identifiable, Equatable {
    let id: String                 // "yyyy-MM-dd" local
    let date: Date                 // start of day
    var entries: [RunLogEntry]     // chronological
    var meta: SkiDayMeta?

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = .current; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func key(for date: Date) -> String { keyFormatter.string(from: date) }
    static func group(_ log: [RunLogEntry], meta: [String: SkiDayMeta]) -> [SkiDay] {
        let byKey = Dictionary(grouping: log, by: { $0.dayKey })
        return byKey.map { key, entries in
            SkiDay(id: key, date: Calendar.current.startOfDay(for: entries.map(\.date).min() ?? Date()),
                   entries: entries.sorted { $0.date < $1.date }, meta: meta[key])
        }.sorted { $0.date > $1.date }
    }
}
```

#### `Models/TrailFilter.swift`
```swift
import Foundation

struct TrailFilter: Equatable, Hashable, Codable, Sendable {
    var areas: Set<Area> = Set(Area.allCases)
    var subAreas: Set<SubArea>? = nil
    var ratingRange: ClosedRange<Int> = 1...100
    var statuses: Set<TrailStatus> = Set(TrailStatus.allCases)
    var grooming: Set<Grooming>? = nil
    var gladedOnly: Bool = false
    var readyForMe: Bool = false
    var searchText: String = ""

    init() {}
    init(searchText: String) { self.searchText = searchText }
    var isActive: Bool { self != TrailFilter(searchText: searchText) }

    /// Pure predicate; `isReady` comes from the progression engine.
    func matches(trail: Trail, rating: Int, state: UserTrailState, isReady: Bool) -> Bool {
        guard areas.contains(trail.area) else { return false }
        if let s = subAreas, !s.contains(trail.subArea) { return false }
        guard ratingRange.contains(rating) else { return false }
        guard statuses.contains(state.status) else { return false }
        if let g = grooming, !g.contains(trail.grooming) { return false }
        if gladedOnly && !trail.gladed { return false }
        if readyForMe && !isReady { return false }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && !trail.name.localizedCaseInsensitiveContains(q) { return false }
        return true
    }
}
```

#### `Models/RGBA.swift`
```swift
import SwiftUI
import AppKit

struct RGBA: Hashable, Codable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// "#RRGGBB" or "RRGGBB"
    init(hex: String, alpha: Double = 1) {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: alpha)
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
    static func lerp(_ x: RGBA, _ y: RGBA, _ t: Double) -> RGBA {
        let u = min(max(t, 0), 1)
        return RGBA(r: x.r + (y.r - x.r) * u, g: x.g + (y.g - x.g) * u, b: x.b + (y.b - x.b) * u, a: x.a + (y.a - x.a) * u)
    }
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let gray  = RGBA(hex: "#8E8E93")
}
```

#### `Rating/RatingTypes.swift`
```swift
import Foundation

/// Inputs to RATING_METHOD §3 (S, M, V, prior, grooming, glades).
struct RatingInput: Hashable, Sendable {
    var sustainedGradePct: Double
    var maxGradePct: Double
    var verticalDropM: Double
    var osmDifficulty: OSMDifficulty     // .unknown == no prior
    var grooming: Grooming               // .moguls == "mogul", .backcountry, .unknown == nil
    var gladed: Bool
}

/// Verbatim entry of data/curated_modifiers.json (snake_case keys); all keys optional.
struct CuratedModifiers: Codable, Hashable, Sendable {
    var gated = false
    var hikeTo = false
    var chute = false
    var cliffExposure = 0.0            // 0…1
    var narrow = false
    var traverse = false
    var mogulsTypical: Bool? = nil     // nil → grooming == .moguls
    var trees: Bool? = nil             // nil → gladed
    var notes: String? = nil
    var source: String? = nil

    static let none = CuratedModifiers()
    init() {}

    enum CodingKeys: String, CodingKey {
        case gated, chute, narrow, traverse, trees, notes, source
        case hikeTo = "hike_to", cliffExposure = "cliff_exposure", mogulsTypical = "moguls_typical"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
        hikeTo = try c.decodeIfPresent(Bool.self, forKey: .hikeTo) ?? false
        chute = try c.decodeIfPresent(Bool.self, forKey: .chute) ?? false
        cliffExposure = try c.decodeIfPresent(Double.self, forKey: .cliffExposure) ?? 0
        narrow = try c.decodeIfPresent(Bool.self, forKey: .narrow) ?? false
        traverse = try c.decodeIfPresent(Bool.self, forKey: .traverse) ?? false
        mogulsTypical = try c.decodeIfPresent(Bool.self, forKey: .mogulsTypical)
        trees = try c.decodeIfPresent(Bool.self, forKey: .trees)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

struct RatingComponent: Codable, Hashable, Sendable {
    var key: String        // base | maxPitch | fatigue | terrain | hazards | prior | gate | softCap
    var label: String      // "Sustained grade 60%"
    var points: Double     // signed
    var detail: String     // "150 m window"
}

struct RatingBreakdown: Codable, Hashable, Sendable {
    var total: Int                       // 1…100
    var components: [RatingComponent]    // sum == soft (± rounding)
    var raw: Double
    var afterPrior: Double
    var afterGate: Double
    var soft: Double
    var engineVersion: String
    static let unrated = RatingBreakdown(total: 0, components: [], raw: 0, afterPrior: 0, afterGate: 0, soft: 0, engineVersion: "unrated")
}
```

#### `Rating/DifficultyRating.swift` (STUB → WP1)
```swift
import Foundation

enum DifficultyRating {
    static let version = "rating-v1-2026-11-01"
    /// WP1 replaces this with RATING_METHOD §3.10 (rounding .toNearestOrEven).
    static func breakdown(_ input: RatingInput, _ m: CuratedModifiers = .none) -> RatingBreakdown {
        RatingBreakdown(total: 50, components: [RatingComponent(key: "base", label: "Stub", points: 50, detail: "WP1 pending")],
                        raw: 50, afterPrior: 50, afterGate: 50, soft: 50, engineVersion: version)
    }
    static func rating(_ input: RatingInput, _ m: CuratedModifiers = .none) -> Int { breakdown(input, m).total }
}
```

#### `Data/CatalogLoader.swift`
```swift
import Foundation

enum CatalogLoader {
    enum LoadError: Error, CustomStringConvertible {
        case missingResource
        var description: String { "trails.json not found in the resource bundle" }
    }
    static func resourceURL() -> URL? {
        if let u = DevHooks.catalogURL { return u }
        return Bundle.appResources.url(forResource: "trails", withExtension: "json", subdirectory: "Resources")
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
```

#### `Style/Ramp.swift` (STUB → WP2; signatures are the contract)
```swift
import SwiftUI

/// UX_SPEC §8.1 continuous 1–100 ramp. WP2 implements; stub returns gray.
enum Ramp {
    static let stops: [(rating: Int, color: RGBA)] = [
        (1, RGBA(hex: "#3BD07C")), (15, RGBA(hex: "#2EC4A0")), (25, RGBA(hex: "#2E9BF0")), (40, RGBA(hex: "#2F6BE6")),
        (50, RGBA(hex: "#5A4FD8")), (62, RGBA(hex: "#7E3FC9")), (75, RGBA(hex: "#B8336A")), (88, RGBA(hex: "#C8102E")),
        (100, RGBA(hex: "#4A0010")),
    ]
    static func color(for rating: Int) -> RGBA { .gray }                 // WP2: piecewise-linear sRGB between stops
    static func doneColor(for rating: Int) -> RGBA { .gray }             // WP2: desaturate 70 %, lightness +15 %
    static func textColor(on background: RGBA) -> RGBA { .white }        // WP2: luminance > 0.5 → #0B2E1A else white
    static func swiftUIColor(for rating: Int) -> Color { color(for: rating).color }
    static let doneGreen = RGBA(hex: "#34C759")
    static let bucketYellow = RGBA(hex: "#FFD60A")
    static let dimmedGray = RGBA(hex: "#8E8E93")
    static let connectorGray = RGBA(hex: "#C7C7CC")
    static let liftGray = RGBA(hex: "#3A3A3C")
}
```

#### `Style/TrailStyleBuilder.swift` (STUB → WP2)
```swift
import Foundation

struct StyleContext: Hashable {
    var isVisible: Bool          // passes TrailFilter
    var isSelected: Bool
    var isHovered: Bool
    var base: MapBaseStyle
}

enum TrailStyleBuilder {
    /// Pure. UX_SPEC §2.2 table. WP2 implements.
    static func style(rating: Int, status: TrailStatus, name: String, context: StyleContext) -> TrailStyle {
        TrailStyle(color: Ramp.color(for: rating), casing: .white, opacity: 1, baseWidth: 2.5, dash: nil,
                   badge: .none, emphasis: .normal, label: context.isSelected ? name : nil)
    }
    /// Convenience over the whole catalog; MainActor because it reads the store.
    @MainActor
    static func styles(for store: AppStore) -> [Trail.ID: TrailStyle] {
        var out: [Trail.ID: TrailStyle] = [:]
        for t in store.catalog.trails {
            let ctx = StyleContext(isVisible: store.isVisible(t), isSelected: store.selection == t.id,
                                   isHovered: store.hover == t.id, base: store.mapBaseStyle)
            out[t.id] = style(rating: store.effectiveRating(t), status: store.state(for: t.id).status, name: t.name, context: ctx)
        }
        return out
    }
}
```

#### `Progression/ProgressionTypes.swift`
```swift
import Foundation

struct SkillEstimate: Equatable, Sendable {
    var value: Double
    var low: Double
    var high: Double
    var basisRuns: Int
    var isProvisional: Bool { basisRuns < 3 }
    var rounded: Int { Int(value.rounded()) }
}

struct Readiness: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case belowYou, ready, stretch, bigStretch }
    var kind: Kind
    var delta: Int            // rating − round(skill)
    var reason: String
}

protocol ProgressionEngine: Sendable {
    /// Relative to the skill estimate, e.g. -7...7.
    var readyWindow: ClosedRange<Int> { get }
    func skillHistory(profile: UserProfile, log: [RunLogEntry], ratings: [Trail.ID: Int]) -> [SkillPoint]
    func currentSkill(history: [SkillPoint], profile: UserProfile) -> SkillEstimate
    func readiness(rating: Int, modifiers: CuratedModifiers, skill: SkillEstimate) -> Readiness
    func readyFor(trails: [Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate, limit: Int) -> [Trail.ID]
    func suggestedNext(bucket: [Trail.ID], trails: [Trail.ID: Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate) -> (id: Trail.ID, reason: String)?
}

enum MilestoneEvaluation: Equatable, Sendable { case locked(fraction: Double?), achieved }

struct MilestoneContext: Sendable {
    let userData: UserData
    let catalog: TrailCatalog
    let ratings: [Trail.ID: Int]       // effective ratings
}

struct Milestone: Identifiable, Sendable {
    let id: String                     // e.g. "first.green", "trail.gunbarrel", "area.bothStates", "count.25"
    let title: String
    let symbol: String                 // SF Symbol
    let detail: String                 // predicate in words
    let evaluate: @Sendable (MilestoneContext) -> MilestoneEvaluation
}
```

#### `Progression/DefaultProgressionEngine.swift` (STUB → WP5)
```swift
import Foundation

struct DefaultProgressionEngine: ProgressionEngine {
    var readyWindow: ClosedRange<Int> { -7...7 }
    func skillHistory(profile: UserProfile, log: [RunLogEntry], ratings: [Trail.ID: Int]) -> [SkillPoint] {
        [SkillPoint(date: profile.startDate, value: Double(profile.selfAssessedStart), low: Double(profile.selfAssessedStart) - 10, high: Double(profile.selfAssessedStart) + 10, runCount: 0)]
    }
    func currentSkill(history: [SkillPoint], profile: UserProfile) -> SkillEstimate {
        let v = history.last?.value ?? Double(profile.selfAssessedStart)
        return SkillEstimate(value: v, low: v - 10, high: v + 10, basisRuns: history.last?.runCount ?? 0)
    }
    func readiness(rating: Int, modifiers: CuratedModifiers, skill: SkillEstimate) -> Readiness {
        let d = rating - skill.rounded
        let kind: Readiness.Kind = d <= -8 ? .belowYou : d <= 7 ? .ready : d <= 15 ? .stretch : .bigStretch
        return Readiness(kind: kind, delta: d, reason: "stub")
    }
    func readyFor(trails: [Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate, limit: Int) -> [Trail.ID] { [] }
    func suggestedNext(bucket: [Trail.ID], trails: [Trail.ID: Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate) -> (id: Trail.ID, reason: String)? { nil }
}
```

#### `Progression/Milestones.swift` (STUB → WP5)
```swift
import Foundation

enum MilestoneRegistry {
    static let all: [Milestone] = []     // WP5: UX_SPEC §7.6 registry
    static func evaluate(_ m: Milestone, in context: MilestoneContext) -> MilestoneEvaluation { m.evaluate(context) }
    /// Achieved now and not yet in profile.unlockedMilestones.
    static func newlyAchieved(in context: MilestoneContext) -> [Milestone] {
        all.filter { context.userData.profile.unlockedMilestones[$0.id] == nil && $0.evaluate(context) == .achieved }
    }
}
```

#### `Persistence/UserDataStore.swift` (STUB → WP2; signatures binding)
```swift
import Foundation

/// JSON document persistence (DESIGN §9). WP2 implements; the stub keeps everything in memory.
final class UserDataStore {
    enum LoadResult {
        case loaded(UserData)
        case fresh
        case recoveredFromBackup(UserData)
        case corrupt(movedTo: URL?, error: Error)
        case newerSchema(Int)
    }
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("userdata.json") }
    var backupURL: URL { directory.appendingPathComponent("userdata.backup.json") }

    static func defaultDirectory() -> URL {
        if let d = DevHooks.userDataDirectory { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SkiLo", isDirectory: true)
    }
    init(directory: URL) { self.directory = directory }

    func load() -> LoadResult { .fresh }                 // WP2
    func scheduleSave(_ data: UserData) {}               // WP2: 500 ms debounce, atomic write, backup rotation
    func flush() {}                                      // WP2: synchronous write if dirty
    static func encode(_ data: UserData) throws -> Data {  // WP2: iso8601, prettyPrinted, sortedKeys
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(data)
    }
    static func decode(_ data: Data) throws -> UserData {  // WP2: run Migrations first
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(UserData.self, from: data)
    }
}
```

#### `Persistence/Migrations.swift` (STUB → WP2)
```swift
import Foundation
enum Migrations {
    static let currentVersion = UserData.currentSchemaVersion
    /// Applies v(n)→v(n+1) dictionary transforms until currentVersion. Throws on a newer version.
    static func run(json: [String: Any], from version: Int) throws -> [String: Any] { json }
}
```

#### `Persistence/ExportImport.swift` (STUB → WP2)
```swift
import Foundation
struct ImportSummary: Equatable { var doneCount: Int; var runCount: Int; var bucketCount: Int; var earliestDate: Date? }
enum ExportImport {
    static func export(_ data: UserData, to url: URL) throws {}                       // WP2: document + "exportedAt"
    static func read(from url: URL) throws -> (UserData, ImportSummary) {             // WP2: decode with migrations
        (UserData.fresh(), ImportSummary(doneCount: 0, runCount: 0, bucketCount: 0, earliestDate: nil))
    }
}
```

#### `Store/Toast.swift`
```swift
import Foundation

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case info, done, bucket, milestone, error }
    struct Action: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let handler: @MainActor () -> Void
        init(_ title: String, _ handler: @escaping @MainActor () -> Void) { self.title = title; self.handler = handler }
        static func == (l: Action, r: Action) -> Bool { l.id == r.id }
    }
    let id = UUID()
    var kind: Kind
    var text: String
    var symbol: String
    var actions: [Action] = []
    var autoDismissSeconds: Double = 4
    init(kind: Kind, text: String, symbol: String, actions: [Action] = [], autoDismissSeconds: Double = 4) {
        self.kind = kind; self.text = text; self.symbol = symbol; self.actions = actions; self.autoDismissSeconds = autoDismissSeconds
    }
}
```

#### `Store/AppStore.swift` (STUB → WP2; the **interface** is binding, bodies are naive)
```swift
import Foundation
import AppKit
import Observation

enum SidebarSection: String, CaseIterable, Codable, Sendable {
    case map, trails, bucket, progress, log
    var title: String {
        switch self { case .map: "Map"; case .trails: "Trails"; case .bucket: "Bucket List"; case .progress: "Progress"; case .log: "Log" }
    }
    var symbol: String {
        switch self {
        case .map: "map.fill"; case .trails: "list.bullet.rectangle"; case .bucket: "star.fill"
        case .progress: "chart.line.uptrend.xyaxis"; case .log: "book.closed.fill"
        }
    }
}

struct LogRunRequest: Identifiable, Equatable {
    let id = UUID()
    var trailID: Trail.ID?
    var date: Date = .now
    var existing: RunLogEntry? = nil       // edit mode
}

struct StatusChange: Equatable {
    var trailID: Trail.ID
    var badge: TrailStyle.Badge
    var revision: Int
}

@Observable @MainActor
final class AppStore {
    // MARK: static data
    let catalog: TrailCatalog
    let trailsByID: [Trail.ID: Trail]

    // MARK: persisted
    private(set) var userData: UserData
    /// Incremented on every userData mutation; views/map use it as a cheap change key.
    private(set) var revision: Int = 0

    // MARK: session / UI
    var filter = TrailFilter()
    var selection: Trail.ID?
    var hover: Trail.ID?
    var section: SidebarSection = .map
    var inspectorShown = true
    var legendShown = true
    var mapBaseStyle: MapBaseStyle = .satellite
    var cameraRequest: CameraPreset?            // MapScreen consumes and sets back to nil
    var lastStatusChange: StatusChange?         // MapScreen animates and clears
    var toast: Toast?
    var logRunRequest: LogRunRequest?           // RootView presents LogRunSheet
    var showOnboarding = false
    weak var undoManager: UndoManager?

    // MARK: collaborators
    let progression: any ProgressionEngine
    let persistence: UserDataStore?

    init(catalog: TrailCatalog, userData: UserData, persistence: UserDataStore?, progression: any ProgressionEngine = DefaultProgressionEngine()) {
        self.catalog = catalog
        self.trailsByID = catalog.trailsByID
        self.userData = userData
        self.persistence = persistence
        self.progression = progression
        self.showOnboarding = !userData.profile.onboardingDone && !DevHooks.skipOnboarding
    }

    /// Loads the bundled catalog and the user document. WP2 handles LoadResult cases + alerts.
    static func bootstrap() -> AppStore {
        let catalog: TrailCatalog
        do { catalog = try CatalogLoader.loadBundled() } catch {
            NSLog("FATAL: \(error)")
            catalog = TrailCatalog(schemaVersion: 1, resort: "Heavenly Mountain Resort", generatedAt: "", source: Provenance(osm: "", license: "", osmTimestamp: "", elevation: "", pipeline: "", modifiersVersion: ""), ratingEngineVersion: DifficultyRating.version, bounds: GeoBounds(minLat: 38.914, minLon: -119.943, maxLat: 38.966, maxLon: -119.881), trails: [], connectors: [], lifts: [], boundary: [])
        }
        let store = UserDataStore(directory: UserDataStore.defaultDirectory())
        let data: UserData
        switch store.load() {
        case .loaded(let d), .recoveredFromBackup(let d): data = d
        default: data = .fresh()
        }
        return AppStore(catalog: catalog, userData: data, persistence: store)
    }

    // MARK: derived (read-only)
    func trail(_ id: Trail.ID) -> Trail? { trailsByID[id] }
    func state(for id: Trail.ID) -> UserTrailState { userData.state(for: id) }
    func effectiveRating(_ id: Trail.ID) -> Int { state(for: id).ratingOverride ?? (trailsByID[id]?.rating.total ?? 0) }
    func effectiveRating(_ t: Trail) -> Int { effectiveRating(t.id) }
    var effectiveRatings: [Trail.ID: Int] { Dictionary(uniqueKeysWithValues: catalog.trails.map { ($0.id, effectiveRating($0)) }) }
    var skill: SkillEstimate { progression.currentSkill(history: userData.profile.skillHistory, profile: userData.profile) }
    func readiness(for id: Trail.ID) -> Readiness {
        progression.readiness(rating: effectiveRating(id), modifiers: trailsByID[id]?.modifiers ?? .none, skill: skill)
    }
    func isVisible(_ t: Trail) -> Bool {
        filter.matches(trail: t, rating: effectiveRating(t), state: state(for: t.id), isReady: readiness(for: t.id).kind == .ready)
    }
    var visibleTrails: [Trail] { catalog.trails.filter(isVisible) }
    var doneCount: Int { catalog.trails.filter { state(for: $0.id).isDone }.count }
    var bucketPending: [Trail.ID] { userData.bucketOrder.filter { state(for: $0).status == .bucket } }
    var bucketCrossedOff: [Trail.ID] {
        catalog.trails.map(\.id).filter { let s = state(for: $0); return s.isDone && s.bucketedAt != nil }
            .sorted { (state(for: $0).lastDoneDate ?? .distantPast) > (state(for: $1).lastDoneDate ?? .distantPast) }
    }
    var skiDays: [SkiDay] { SkiDay.group(userData.runLog, meta: userData.skiDays) }

    // MARK: mutations (WP2: undo registration, persistence, toasts, haptics, milestones, skill recompute)
    func markDone(_ id: Trail.ID, on date: Date = .now, backfilled: Bool = false) {
        mutate("Mark Done") { d in
            var s = d.state(for: id)
            s.status = .done; s.firstDoneDate = s.firstDoneDate ?? date; s.lastDoneDate = date
            s.backfilled = s.backfilled || backfilled; s.timesSkied = max(s.timesSkied, 1)
            d.trailStates[id] = s
        }
        lastStatusChange = StatusChange(trailID: id, badge: .done, revision: revision)
    }
    func markDone(_ ids: [Trail.ID], backfilled: Bool) { for id in ids { markDone(id, backfilled: backfilled) } }
    func markNotDone(_ id: Trail.ID) {
        mutate("Mark Not Done") { d in
            var s = d.state(for: id)
            s.status = s.bucketedAt != nil ? .bucket : .notDone
            s.firstDoneDate = nil; s.lastDoneDate = nil
            d.trailStates[id] = s.isEmpty ? nil : s
        }
        lastStatusChange = StatusChange(trailID: id, badge: state(for: id).bucketedAt != nil ? .bucket : .none, revision: revision)
    }
    func toggleDone(_ id: Trail.ID) { state(for: id).isDone ? markNotDone(id) : markDone(id) }
    func addToBucket(_ ids: [Trail.ID]) {
        mutate("Add to Bucket List") { d in
            for id in ids {
                var s = d.state(for: id)
                if s.bucketedAt == nil { s.bucketedAt = .now }
                if s.status == .notDone { s.status = .bucket }
                d.trailStates[id] = s
                if !d.bucketOrder.contains(id) { d.bucketOrder.append(id) }
            }
        }
    }
    func removeFromBucket(_ id: Trail.ID) {
        mutate("Remove from Bucket List") { d in
            var s = d.state(for: id)
            s.bucketedAt = nil
            if s.status == .bucket { s.status = .notDone }
            d.trailStates[id] = s.isEmpty ? nil : s
            d.bucketOrder.removeAll { $0 == id }
        }
    }
    func toggleBucket(_ id: Trail.ID) { state(for: id).bucketedAt == nil ? addToBucket([id]) : removeFromBucket(id) }
    func moveBucket(from: IndexSet, to: Int) { mutate("Reorder Bucket List") { $0.bucketOrder.move(fromOffsets: from, toOffset: to) } }
    func logRun(_ entry: RunLogEntry, alsoMarkDone: Bool) {
        var e = entry
        e.isFirstTime = userData.runLog.first { $0.trailID == entry.trailID } == nil
        mutate("Log Run") { d in
            d.runLog.append(e)
            var s = d.state(for: e.trailID); s.timesSkied += 1; d.trailStates[e.trailID] = s
        }
        if alsoMarkDone && !state(for: e.trailID).isDone { markDone(e.trailID, on: e.date) }
    }
    func updateRun(_ entry: RunLogEntry) { mutate("Edit Run") { d in if let i = d.runLog.firstIndex(where: { $0.id == entry.id }) { d.runLog[i] = entry } } }
    func deleteRun(_ id: UUID) { mutate("Delete Run") { $0.runLog.removeAll { $0.id == id } } }
    func setSkiDayMeta(_ key: String, _ meta: SkiDayMeta) { mutate("Edit Ski Day") { $0.skiDays[key] = meta } }
    func setOverride(_ id: Trail.ID, rating: Int?, note: String?) {
        mutate("Override Rating") { d in var s = d.state(for: id); s.ratingOverride = rating; s.ratingOverrideNote = note; d.trailStates[id] = s.isEmpty ? nil : s }
    }
    func setNotes(_ id: Trail.ID, _ text: String) {
        mutate("Edit Notes") { d in var s = d.state(for: id); s.notes = text; d.trailStates[id] = s.isEmpty ? nil : s }
    }
    func completeOnboarding(selfAssessed: Int, backfill: Set<Band>) {
        mutate("Onboarding") { d in d.profile.selfAssessedStart = selfAssessed; d.profile.onboardingDone = true; d.profile.startDate = .now }
        let ids = catalog.trails.filter { backfill.contains(Band.of($0.rating.total)) }.map(\.id)
        if !ids.isEmpty { markDone(ids, backfilled: true) }
        showOnboarding = false
    }
    func replaceUserData(_ data: UserData, actionName: String) { mutate(actionName) { $0 = data } }
    func resetAllUserData() { replaceUserData(.fresh(), actionName: "Reset All Data") }
    func flush() { persistence?.flush() }

    // MARK: UI helpers
    func select(_ id: Trail.ID?, showInspector: Bool) { selection = id; if id != nil && showInspector { inspectorShown = true } }
    func showOnMap(_ id: Trail.ID) { section = .map; select(id, showInspector: true); cameraRequest = .fit(id) }
    func requestCamera(_ p: CameraPreset) { cameraRequest = p }
    func requestLogRun(trailID: Trail.ID?) { logRunRequest = LogRunRequest(trailID: trailID ?? selection) }
    func showToast(_ t: Toast) { toast = t }

    // MARK: core mutation path (WP2 adds undo + persistence + derived recompute)
    private func mutate(_ actionName: String, _ body: (inout UserData) -> Void) {
        body(&userData)
        userData.updatedAt = .now
        revision += 1
        persistence?.scheduleSave(userData)
    }
}
```

#### `Map/MapEngine.swift`
Copy **DESIGN.md §7** verbatim (the code block from `struct MapScene` through the end of
`protocol MapEngine`).

#### `Map/MapHostView.swift`
```swift
import SwiftUI
import AppKit

struct MapHostView: NSViewRepresentable {
    let engine: any MapEngine
    func makeNSView(context: Context) -> NSView { engine.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

#### `Map/MapSceneBuilder.swift` (STUB → WP3)
```swift
enum MapSceneBuilder {
    static func scene(from catalog: TrailCatalog) -> MapScene {
        MapScene(trails: [], connectors: [], lifts: [], boundary: catalog.boundary, bounds: catalog.bounds)
    }
}
```

#### `Map/CameraPresets.swift` (STUB → WP3)
```swift
import Foundation
enum CameraPresets {
    static let overview = CameraState(center: GeoCoordinate(lat: 38.938, lon: -119.913), distanceM: 11_000, headingDeg: 180, pitchDeg: 35)
    /// Pure; DESIGN §8.6. `current` is used for `.fit` heading.
    static func state(for preset: CameraPreset, scene: MapScene, viewSize: CGSize, current: CameraState?) -> CameraState { overview }
}
```

#### `Map/Picking.swift` (STUB → WP3)
```swift
import Foundation
struct ProjectedPolyline { let trailID: Trail.ID; let points: [CGPoint?] }
enum Picking {
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(p.x - a.x, p.y - a.y) }
    /// Nearest trail segment within `threshold` points; one result per trail id.
    static func nearest(to p: CGPoint, in polylines: [ProjectedPolyline], bounds: CGRect, threshold: CGFloat) -> (id: Trail.ID, distance: CGFloat)? { nil }
}
```

#### `Map/MapKitEngine.swift` (STUB → WP3)
```swift
import AppKit
import MapKit

@MainActor
final class MapKitEngine: NSObject, MapEngine {
    static let displayName = "Apple Maps (MapKit)"
    var capabilities: MapEngineCapabilities { [] }
    var supportedBaseStyles: [MapBaseStyle] { MapBaseStyle.allCases }
    weak var delegate: (any MapEngineDelegate)?
    private var camera = CameraPresets.overview
    private let view: NSView = { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.darkGray.cgColor; return v }()
    func makeView() -> NSView { view }
    func load(scene: MapScene) {}
    func apply(styles: [Trail.ID: TrailStyle]) {}
    func setSelection(_ id: Trail.ID?) {}
    func setBaseStyle(_ style: MapBaseStyle) {}
    func setCamera(_ preset: CameraPreset, animated: Bool) {}
    func setCamera(_ state: CameraState, animated: Bool) { camera = state }
    func animateStatusChange(_ id: Trail.ID, to badge: TrailStyle.Badge) {}
    func currentCamera() -> CameraState { camera }
    func project(_ c: GeoCoordinate) -> CGPoint? { nil }
    func hitTest(_ point: CGPoint) -> Trail.ID? { nil }
}
```

#### View stubs
Every view stub is `struct X: View { var body: some View { Text("X — WPn pending") } }` with the
initializer the consumers need. Required initializers (so other packages compile against them):

```swift
struct RootView: View          { init() ; body = MapScreen() }             // WP4 — stub body shows MapScreen so WP3 can screenshot
struct SidebarView: View       { init() }                                   // WP4
struct MiniProgressCard: View  { init() }                                   // WP4
struct MapScreen: View         { init() }                                   // WP3
struct MapOverlays: View       { init(engine: any MapEngine, viewSize: CGSize) }  // WP3
struct TrailsScreen: View      { init() }                                   // WP4
struct TrailInspector: View    { init() }                                   // WP4
struct ElevationProfileChart: View { init(trail: Trail, units: Units) }     // WP4
struct RatingBreakdownView: View   { init(breakdown: RatingBreakdown, override: Int?, note: String?) }  // WP4
struct OverridePopover: View       { init(trailID: Trail.ID, isPresented: Binding<Bool>) }              // WP4
struct SettingsView: View      { init() }                                   // WP4
struct OnboardingSheet: View   { init() }                                   // WP4
struct BucketScreen: View      { init() }                                   // WP5
struct AddTrailPopover: View   { init(isPresented: Binding<Bool>) }         // WP5
struct LogScreen: View         { init() }                                   // WP5
struct LogRunSheet: View       { init(request: LogRunRequest) }             // WP5 — presented by RootView via store.logRunRequest
struct EditDaySheet: View      { init(dayKey: String, isPresented: Binding<Bool>) }  // WP5
struct ProgressScreen: View    { init() }                                   // WP5
struct ToastView: View         { init(toast: Toast, dismiss: @escaping () -> Void) } // WP4
struct AppCommands: Commands   { init(store: AppStore); body = EmptyCommands() }     // WP4
```

#### Shared views (FULL minimal; WP4 may polish)
```swift
struct RatingPill: View      { init(rating: Int, isOverride: Bool = false, size: Font = .title2) }  // capsule filled with Ramp.color, text Ramp.textColor
struct BandSymbol: View      { init(band: Band) }                        // SF symbol; doubleBlack = two diamonds with -2 pt spacing
struct StatusGlyph: View     { init(status: TrailStatus) }               // ✓ green / ★ yellow / blank
struct ReadinessChip: View   { init(readiness: Readiness) }              // ready #34C759, stretch #FF9F0A, bigStretch #FF453A, belowYou #8E8E93
enum Format {                                                           // Views/Shared/Format.swift
    static func length(_ m: Double, _ u: Units) -> String   // "0.9 mi" / "1.4 km"
    static func elevation(_ m: Double, _ u: Units) -> String // "8,250 ft" / "2,516 m"
    static func vert(_ m: Double, _ u: Units) -> String      // same as elevation, no decimals
    static func grade(_ pct: Double) -> String               // "31%"
    static func date(_ d: Date) -> String                    // "Jan 14, 2026"
    static func time(_ d: Date) -> String                    // "10:05"
}
```

#### `Resources/trails.json` placeholder (final schema, 2 trails, hand-written)
Use real numbers for Gunbarrel (`t-gunbarrel`, CA, gunbarrelFace, expert, moguls, stats from
`data/trails.json`, 4 geometry points: top `[-119.934512,38.931384,2316.1]` … bottom
`[-119.939545,38.934659,2030.6]`, modifiers `{"moguls_typical": true}`) and Maggie's (`t-maggie-s`,
easy, groomed, CA, gunbarrelFace; copy `stats` from `data/trails.json`), one lift (`l-313466574`
Gunbarrel Express), one connector, the real boundary ring is optional (an empty `boundary: []` is
valid). `expectedRating` may be omitted (null) in the placeholder. `ratingEngineVersion` =
`rating-v1-2026-11-01`. WP1 overwrites this file.

#### `Tests/SkiLoTests/TestSupport.swift`
```swift
import Foundation
import Testing
@testable import SkiLo

enum TestPaths {
    /// Repo root derived from this file's compile-time path (works in copies of the tree too).
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func data(_ relative: String) -> URL { repoRoot.appendingPathComponent("data").appendingPathComponent(relative) }
    static func scratchDirectory(_ name: String) throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SkiLoTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum Fixtures {
    static func bundledCatalog() throws -> TrailCatalog { try CatalogLoader.loadBundled() }
    static func userData(done: [Trail.ID] = [], bucket: [Trail.ID] = []) -> UserData {
        var d = UserData.fresh()
        for id in done { var s = UserTrailState(); s.status = .done; s.firstDoneDate = Date(); s.lastDoneDate = Date(); s.timesSkied = 1; d.trailStates[id] = s }
        for id in bucket { var s = d.state(for: id); s.bucketedAt = Date(); if s.status == .notDone { s.status = .bucket }; d.trailStates[id] = s; d.bucketOrder.append(id) }
        d.profile.onboardingDone = true
        return d
    }
    @MainActor
    static func makeStore(userData: UserData = Fixtures.userData()) throws -> AppStore {
        AppStore(catalog: try bundledCatalog(), userData: userData, persistence: nil)
    }
}
```

#### `Tests/SkiLoTests/SmokeTests.swift`
```swift
import Testing
import Foundation
@testable import SkiLo

@Suite("Scaffold smoke tests")
struct SmokeTests {
    @Test func bundledCatalogDecodes() throws {
        let c = try Fixtures.bundledCatalog()
        #expect(c.resort == "Heavenly Mountain Resort")
        #expect(c.schemaVersion == 1)
        #expect(!c.trails.isEmpty)
        #expect(c.trails.allSatisfy { $0.id.hasPrefix("t-") })
    }
    @Test func geoCoordinateRoundTrips() throws {
        let c = GeoCoordinate(lat: 38.93, lon: -119.94, ele: 2030.5)
        let data = try JSONEncoder().encode([c])
        #expect(String(data: data, encoding: .utf8) == "[[-119.94,38.93,2030.5]]")
        #expect(try JSONDecoder().decode([GeoCoordinate].self, from: data) == [c])
    }
    @Test func userDataDecodesMissingKeys() throws {
        let d = try JSONDecoder().decode(UserData.self, from: Data("{\"trailStates\":{\"t-x\":{\"status\":\"done\"}}}".utf8))
        #expect(d.state(for: "t-x").isDone)
        #expect(d.state(for: "t-x").notes == "")
    }
    @MainActor @Test func storeMarksDone() throws {
        let s = try Fixtures.makeStore()
        let id = s.catalog.trails[0].id
        s.markDone(id)
        #expect(s.state(for: id).isDone)
        #expect(s.doneCount == 1)
        #expect(s.revision == 1)
    }
}
```

### WP0.3 Verify (all must pass before announcing "scaffold landed")

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -20   # 0 errors
tools/run_tests.sh 2>&1 | tail -8                                                       # "✔ Test run with 4 tests in 1 suite passed"
tools/build_app.sh verify                                                               # window appears, build/verify.png written, exit 0
```
Read `build/verify.png`: a window with a dark-gray map placeholder (stub engine) is the expected result.

### WP0.4 Acceptance
- Every file in the WP0 tree exists with the exact type names/signatures above.
- `swift build` 0 errors; `tools/run_tests.sh` reports 4 passed; `make verify` exit 0; screenshot viewed.
- Report: list of files, build/test output tails, and any signature you had to change (should be none).

---

## WP1 — Data & Rating (`wp1-data-rating`)

### Files (creates/edits; nothing else)
```
tools/build_catalog.py                               NEW (python3 -I, stdlib only: json, re, math, sys, datetime, argparse)
data/overrides/trail_overrides.json                  NEW
Sources/SkiLo/Resources/trails.json        REPLACES WP0 placeholder (generated, ~0.7 MB)
Makefile                                             EDIT the sync-data target only (WP0 already changed `test`)
Sources/SkiLo/Rating/DifficultyRating.swift REPLACES stub
Tests/SkiLoTests/RatingTests.swift         NEW
Tests/SkiLoTests/CatalogTests.swift        NEW
data/README.md                                       NEW (optional: one page on the files and rerun commands)
```

### WP1.1 `tools/build_catalog.py`
Inputs: `data/trails.json`, `data/lifts.json`, `data/boundary.json`, `data/curated_modifiers.json`,
`data/overrides/trail_overrides.json`, `data/calibration_anchors.json` (for validation only).
Output: `Sources/SkiLo/Resources/trails.json` exactly per DESIGN §4 (also `--out PATH`).
Rules: DESIGN §4.5 (slug, ids, area, subArea, grooming mapping, geometry, midpoint, profile grade,
stats rename, modifiers verbatim, `expectedRating` via the RATING_METHOD Appendix B Python
reference, bounds). Print a summary (counts, 6-band histogram, anchors check) and exit 1 on any
validation failure. `generatedAt` = UTC now ISO-8601. Keep float values as Python reads them (no rounding).

`data/overrides/trail_overrides.json`:
```json
{
  "_about": "Hand corrections applied last by tools/build_catalog.py. Keys are exact OSM names.",
  "areaByName": {},
  "liftNameByName": {},
  "subAreaByName": {
    "Pipeline": "killebrewCanyon", "Outer Limits": "killebrewCanyon", "The Fingers": "killebrewCanyon",
    "Ramarah's": "killebrewCanyon", "Bobs Boulevard": "killebrewCanyon", "Boundry Chutes": "killebrewCanyon",
    "Meadows": "killebrewCanyon", "Pac-Man": "killebrewCanyon", "Under the Gun": "killebrewCanyon",
    "Sweetwater": "killebrewCanyon", "Rim Trail": "killebrewCanyon",
    "Bill's": "mottCanyon", "Ernie's": "mottCanyon", "Hemlock": "mottCanyon", "Hully Gully": "mottCanyon",
    "Mott Canyon Trail": "mottCanyon", "North 40": "mottCanyon", "On Hold": "mottCanyon", "Pinenuts": "mottCanyon",
    "Promised Land": "mottCanyon", "Snake Eyes": "mottCanyon", "Southern Comfort": "mottCanyon",
    "Stateline": "mottCanyon", "The \"Y\"": "mottCanyon", "Widow Maker": "mottCanyon",
    "Milky Way Bowl": "dipperComet", "Pinnacles": "skyCanyonPowderbowl", "Backstroke": "tamarackTop"
  },
  "liftPods": {
    "gunbarrelFace": ["Gunbarrel Express", "World Cup", "Aerial Tramway", "Patsy's", "First Ride", "Groove", "Pioneer", "Big Easy", "Tubing Hill"],
    "skyCanyonPowderbowl": ["Sky Express", "Canyon Express", "Powderbowl Express", "Heavenly Gondola"],
    "tamarackTop": ["Tamarack Express"],
    "dipperComet": ["Dipper Express", "Comet Express"],
    "olympicStagecoach": ["Olympic Express", "Stagecoach Express"],
    "boulderGalaxyNorthBowl": ["Boulder", "Galaxy", "North Bowl Express", "Unnamed magic carpet"],
    "mottCanyon": ["Mott Canyon"]
  }
}
```

`Makefile` sync-data target becomes:
```make
PY ?= /Users/calebsuh/miniconda3/bin/python3
sync-data:
	@test -f data/trails.json || { echo "data/trails.json not found (run tools/build_trails.py first)"; exit 1; }
	$(PY) -I tools/build_catalog.py
	@echo ">> wrote Sources/$(APP_NAME)/Resources/trails.json"
```

### WP1.2 `Rating/DifficultyRating.swift`
Port RATING_METHOD §3.10 exactly, with these adaptations:
- `RatingInput` instead of `TrailStats`; `osmDifficulty == .unknown` ⇒ no prior (floor 0, ceiling 100);
  `grooming == .moguls` ⇔ "mogul", `.backcountry`, `.unknown` ⇔ nil.
- `let rating = Int(clamp(s.rounded(.toNearestOrEven), 1, 100))` (matches Python `round`).
- Build `components` (DESIGN §5): `base` ("Sustained grade \(S)%", detail "150 m window"),
  `maxPitch` ("Max pitch \(M)%", "50 m window"), `fatigue` ("Vertical \(V) m"), `terrain` (label from
  moguls/trees/ungroomed), `hazards` (label lists chute/narrow/traverse/gated/hike-to/cliff), then
  `prior`/`gate`/`softCap` only when their delta ≠ 0 (|Δ| > 0.005). Format numbers with 0 decimals.
- Expose `static func base(_ s: Double) -> Double`, `static func piecewise(_:_:)`, `static let baseKnots`,
  `floors`, `ceilings` (keyed by `OSMDifficulty`) for tests.

### WP1.3 Tests
`RatingTests` (`@Suite("Rating")`):
1. `fixtureExact`: decode `TestPaths.data("calibration_anchors.json")` (struct with `trails: [{name, expected_rating, target, tol, inputs{length_m, vertical_drop_m, avg_grade_pct, max_grade_pct, sustained_grade_pct, p90_grade, osm_difficulty?, grooming?, gladed}}]`), decode `data/curated_modifiers.json` as `[String: CuratedModifiers]`, and `#expect(DifficultyRating.rating(input, mods[name] ?? .none) == expected_rating)` for all 126.
2. `anchorsWithinTolerance`: for entries with `target != nil`, `abs(rating − target) <= tol` (29 anchors).
3. `workedExamples`: Gunbarrel inputs from RATING_METHOD §3.9 → 80; Mott Canyon Trail → 60; Mineshaft → 52.
4. `monotoneInGrade`: for S in stride(0…120 by 1) with M = S + 5, rating non-decreasing; same for M at fixed S.
5. `bounds`: extreme inputs (S=120, M=132, V=2000, all hazards) → ≤ 100; zeros → ≥ 1.

`CatalogTests` (`@Suite("Catalog")`) on the bundled catalog:
1. 126 trails, 34 connectors, 23 lifts, 1 boundary ring with ≥ 300 points.
2. ids unique and match `^t-[a-z0-9-]+$`; `t-gunbarrel`, `t-the-face`, `t-the-y`, `t-100-saddle`, `t-bill-s` exist.
3. `CatalogLoader.validate(catalog).isEmpty`.
4. `trail.rating.total == trail.expectedRating!` for all 126 (Swift == Python).
5. subArea counts: mottCanyon 14, killebrewCanyon 11; `t-gunbarrel`.subArea == .gunbarrelFace; areas: 50 CA / 76 NV.
6. Every trail: ≥ 1 polyline, each ≥ 2 points, every coordinate has `ele`, all inside `catalog.bounds`; `profile` non-empty with ascending `distanceM`; `midpoint` within 1 km of `top`.
7. Six-band spread sanity: at least 10 trails in each of `<25`, `25..<50`, `50..<75`, `≥75`.

### WP1.4 Verify
```sh
/Users/calebsuh/miniconda3/bin/python3 -I tools/build_catalog.py        # exit 0, prints summary
tools/build_app.sh sync-data                                            # same via make
tools/run_tests.sh --filter "Rating|Catalog"                                    # green
tools/run_tests.sh                                                      # everything else still green
ls -la Sources/SkiLo/Resources/trails.json                    # < 1.5 MB
```
### WP1.5 Acceptance
- Script idempotent (two runs → identical file except `generatedAt`).
- All RatingTests + CatalogTests pass; SmokeTests still pass.
- Report includes the band histogram and the 29-anchor table (name, target, tol, swift, python).

---

## WP2 — Core: store, persistence, style (`wp2-core`)

### Files
```
Sources/SkiLo/Store/AppStore.swift              REPLACES stub (keep every public signature; add, never remove)
Sources/SkiLo/Persistence/UserDataStore.swift   REPLACES stub
Sources/SkiLo/Persistence/Migrations.swift      REPLACES stub
Sources/SkiLo/Persistence/ExportImport.swift    REPLACES stub
Sources/SkiLo/Style/Ramp.swift                  REPLACES stub
Sources/SkiLo/Style/TrailStyleBuilder.swift     REPLACES stub
Tests/SkiLoTests/StoreTests.swift               NEW
Tests/SkiLoTests/PersistenceTests.swift         NEW
Tests/SkiLoTests/StyleTests.swift               NEW
```

### WP2.1 `AppStore` (must implement; interface from WP0 is frozen, you may add members)
- `mutate(_:_:)`: snapshot `userData` before `body`; after: `updatedAt`, `revision += 1`,
  `persistence?.scheduleSave`, recompute `profile.skillHistory` when `runLog`/`trailStates` changed
  (`progression.skillHistory(profile:log:ratings:)`), evaluate `MilestoneRegistry.newlyAchieved` and
  record `unlockedMilestones[id] = .now` for each (inside the same mutation), and register undo:
  `undoManager?.registerUndo(withTarget: self) { s in s.restore(snapshot, redoTo: current, actionName:) }`
  with `setActionName`. Undo/redo restore must themselves bump `revision` and schedule a save.
- `markDone`: semantics per UX §2.4/§7.2: `firstDoneDate ??= date`, `lastDoneDate = date`,
  `timesSkied += 1` only if no run is logged for that trail on that day, `status = .done`, keep
  `bucketedAt`. Then: `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)`
  (skip when `backfilled`), `lastStatusChange`, and a toast: "✓ \(name) crossed off" / "★ \(name)
  crossed off your bucket list" with actions `Undo` (→ `undoManager?.undo()`) and, if no run logged
  today, `Log run…` (→ `requestLogRun(trailID:)`). A newly achieved milestone adds a second toast
  (kind `.milestone`, text "🏅 \(title)", action "Show" → `section = .progress`). Bulk `markDone(ids:)`
  is one undo group (`undoManager?.beginUndoGrouping()`/`endUndoGrouping()`), one toast "N trails marked done".
- `markNotDone`: reverse; status returns to `.bucket` if `bucketedAt != nil`; no haptic; toast "\(name) marked not done · Undo".
- `addToBucket`/`removeFromBucket`/`toggleBucket`/`moveBucket`: UX §4; toast "★ Added to bucket list".
- `logRun(_:alsoMarkDone:)`: append entry (`isFirstTime` = no earlier entry for that trail),
  `timesSkied += 1`, mark done if asked (same undo group), toast "Run logged".
- `completeOnboarding(selfAssessed:backfill:)`: UX §1.8; backfilled states have `backfilled = true`.
- `replaceUserData`: used by import and reset; one undo step.
- Invariants from UX §7.2 enforced in a `private func normalize(_ d: inout UserData)` called at the
  end of every mutation: `status == .bucket ⇒ bucketedAt != nil`; `.done ⇒ firstDoneDate != nil`;
  `bucketOrder` contains every `.bucket` id exactly once, unknown ids dropped; empty states pruned.
- `bootstrap()`: handle every `LoadResult` (corrupt → start fresh and set `pendingAlert`
  (`var pendingAlert: StoreAlert?` with title/message/`revealURL`) which RootView shows; `newerSchema` →
  alert + read-only session with `persistence = nil`). Observe `NSApplication.willTerminateNotification`
  → `flush()`. Also persist `section`, `inspectorShown`, `legendShown`, `mapBaseStyle` through
  `UserDefaults` (keys in DESIGN §9) using `didSet`-style observation (`withObservationTracking` or
  explicit setters) — simplest: write in `didSet` of each property.
- Performance: `effectiveRatings` and `visibleTrails` are recomputed on access; cache them keyed by
  `(revision, filter, skill)` if a profile shows > 2 ms per access.

### WP2.2 `UserDataStore`
DESIGN §9 exactly: directory creation, `load()` with backup recovery and corrupt-file rename,
`scheduleSave` debounced 500 ms on a serial `DispatchQueue` (Task-based is fine), atomic write
(`userdata.json.tmp` + `replaceItemAt`, backup rotation), `flush()` synchronous. `encode/decode`
with `.iso8601`, `[.prettyPrinted, .sortedKeys]`; `decode` runs `Migrations.run` on the raw JSON
dictionary first and throws `MigrationError.newerSchema(n)` when `schemaVersion > currentVersion`.

### WP2.3 `ExportImport`
`export` writes the document plus `"exportedAt"` (top-level key added to the dictionary after
encoding). `read` returns data + `ImportSummary`. Merge is **P1**: implement
`static func merge(local: UserData, imported: UserData) -> UserData` per UX §7.8 only after P0 tests pass.

### WP2.4 `Ramp` and `TrailStyleBuilder`
- `Ramp.color(for:)`: clamp 1…100, piecewise-linear sRGB between the stops (`RGBA.lerp`).
  `doneColor`: convert to HSB via `NSColor`, saturation × 0.3, brightness = min(1, b + 0.15).
  `textColor(on:)`: luminance > 0.5 → `#0B2E1A` else white.
- `TrailStyleBuilder.style(rating:status:name:context:)`: UX §2.2 table exactly:

| case | color | casing | opacity | baseWidth | dash | badge | emphasis |
|---|---|---|---|---|---|---|---|
| not visible (filtered out) | `#8E8E93` | none (`.clear`) | 0.15 | 1.5 | nil | none | dimmed |
| notDone | ramp | white (`#1C1C1E` on `.outline`) | 1.0 | 2.5 | nil | none | normal |
| bucket | ramp | `#FFD60A` | 1.0 | 3.0 | nil | bucket | normal |
| done | `Ramp.doneColor` | white/`#1C1C1E` | 0.55 | 2.0 | nil | done | normal |
| + hovered | same | same | same | ×1.3 | | | hovered |
| + selected | same | same | 1.0 | ×1.8 | | | selected (label = name) |

Selected wins over hovered; filtered-out trails can still be selected (then they render selected).

### WP2.5 Tests
`StoreTests`: markDone/markNotDone round trip restores an empty state; bucket → done keeps
`bucketedAt` and appears in `bucketCrossedOff`; `moveBucket`; `logRun` increments `timesSkied` and
sets `isFirstTime` once; bulk markDone is a single undo (use a real `UndoManager`, call `undo()`,
assert all reverted, `redo()` re-applies); invariants after random sequences (100 random ops on 10
trails, then check `normalize` invariants); toast produced on markDone with Undo action; milestones
stay stubbed (registry empty) — just assert no crash.
`PersistenceTests`: save→load round trip in `TestPaths.scratchDirectory`; backup rotation; corrupt
file → `.corrupt(movedTo:)` and the file renamed; newer schema → `.newerSchema`; debounce coalesces
(three `scheduleSave` within 100 ms → one file write; assert via modification count or by flush);
`flush()` writes synchronously; export adds `exportedAt`; import reads it back equal.
`StyleTests`: ramp stops exact (`Ramp.color(for: 1) == #3BD07C` … `100 == #4A0010`), midpoint
interpolation (rating 20 between stops 15 and 25), `textColor`, every row of the style table above.

### WP2.6 Verify / acceptance
`tools/run_tests.sh --filter "Store|Persistence|Style"` green; `swift build` clean; run the bare binary
with `HT_USERDATA_DIR=<scratch> HT_MARK_DONE=t-gunbarrel HT_SCREENSHOT=…` twice and show that the
second launch's `userdata.json` contains the done state (cat the file in the report).

---

## WP3 — Map engine and Map screen (`wp3-map`)

### Files
```
Sources/SkiLo/Map/MapSceneBuilder.swift   REPLACES stub
Sources/SkiLo/Map/CameraPresets.swift     REPLACES stub
Sources/SkiLo/Map/Picking.swift           REPLACES stub
Sources/SkiLo/Map/MapKitEngine.swift      REPLACES stub (may split into MapKitEngine+Overlays.swift, +Picking.swift, +Annotations.swift in Map/)
Sources/SkiLo/Map/MapHostView.swift       may edit
Sources/SkiLo/Views/Map/MapScreen.swift   REPLACES stub
Sources/SkiLo/Views/Map/MapOverlays.swift REPLACES stub (legend, camera chips, hover tooltip, OSM attribution, offline banner)
Tests/SkiLoTests/PickingTests.swift       NEW
Tests/SkiLoTests/CameraPresetsTests.swift NEW
```
Do not touch `Map/MapEngine.swift`. Do not read `AppStore` from inside `Map/*` (only `Views/Map/*` may).

### WP3.1 First 15 minutes: settle the two unknowns with the spike
```sh
cd spikes/mapkit && ./build.sh && SPIKE_STYLE=imagery SPIKE_DELAY=10 SPIKE_DISTANCE=2900 SPIKE_PITCH=60 SPIKE_HEADING=165 ./spike_mk
```
Read `out/mk/shot1_mk_realistic_initial.png`: (a) does imagery mode show 3D relief and pitch? → decides
`.satellite` configuration (DESIGN §8.4); (b) is the gray sky grid visible at 2.9 km / 60° / heading
165? → lower pitch to 55° or distance to 2.6 km for the close presets. Record both answers in a
comment at the top of `MapKitEngine.swift`.

### WP3.2 `MapSceneBuilder.scene(from:)`
`TrailGeometry(id:name:polylines: trail.geometry, midpoint:, bounds:)` for all 126; `connectors`
from `catalog.connectors.map(\.polyline)`; lifts; boundary; bounds.

### WP3.3 `Picking`
Port `pointSegmentDistance` and `pickTrail` from `spikes/mapkit/Shared.swift` as pure functions
over `[ProjectedPolyline]` (nil points break segments), 50 pt viewport padding reject, threshold
14 pt, best per trail id. `PickingTests`: distance to segment (endpoint, interior, degenerate
segment), nearest picks the closer of two parallel lines, threshold excludes, nil points break
segments, bounds reject.

### WP3.4 `CameraPresets.state(for:scene:viewSize:current:)`
DESIGN §8.6 numbers; `.overview` distance × `max(1, 900 / viewSize.width)`; `.fit(id)` from the
trail's `bounds` (look it up in `scene.trails`): `distance = max(1_200, bounds.diagonalM × 2.5)`,
pitch 60 if ≤ 3,000 else 35, heading = `current?.headingDeg ?? 180`. `CameraPresetsTests`: preset
values, fit clamps to ≥ 1,200 m, fit pitch rule, overview scales with narrow views.

### WP3.5 `MapKitEngine`
Implement DESIGN §8.1–§8.8 and §7's contract notes. Checklist (each item is an acceptance item):
1. Configuration per base style; `cameraZoomRange` 1,200–30,000 m; `cameraBoundary` = bounds + 4 km;
   POIs excluded; compass on; pitch/zoom controls off; interaction on.
2. Overlays per DESIGN §8.2 with renderer cache; `apply(styles:)` diffs against `lastStyles` and
   mutates renderers only for changed ids; measure and log the time for a full 126-entry apply (< 2 ms
   target, must be < 10 ms).
3. `setSelection`: remove previous selected overlays, re-add casing + stroke + glow at `.aboveLabels`.
4. Width scaling on `regionDidChangeAnimated` and `cameraDidChange` emission with the **actual**
   camera (`mapView.camera`), also after `setCamera` (use `setCamera(_:animated:)` then read back in
   `regionDidChangeAnimated`).
5. Click → `Picking` → `didSelect(id or nil)`; hover via `NSTrackingArea` (30 Hz throttle, emit on change
   only); projection cache keyed by `(centerCoordinate, altitude, pitch, heading, bounds.size)`.
6. Badges + selected label as `MKAnnotationView`s (DESIGN §8.5); if they misbehave, drop `.badges`/
   `.labels` from `capabilities` and let `MapOverlays` draw them via `project()`.
7. `animateStatusChange` (DESIGN §8.8).
8. `mapViewDidFailLoadingMap` → `.outline` + `didFinishLoading(ok:false)`; `mapViewDidFinishLoadingMap` → `ok: true`.
9. `project()` returns nil for NaN/off-view points; `hitTest` shares the click path.
10. Persist nothing; the engine is stateless beyond the view and caches.

### WP3.6 `MapScreen` + `MapOverlays`
- `@Environment(AppStore.self) var store`; `@State private var engine: any MapEngine = MapKitEngine()`;
  on appear: `engine.delegate = coordinator`, `engine.load(scene: MapSceneBuilder.scene(from: store.catalog))`,
  `engine.setBaseStyle(store.mapBaseStyle)`, restore `UserDefaults["map.lastCamera"]` (JSON `CameraState`)
  else `.overview`; then `engine.apply(styles: TrailStyleBuilder.styles(for: store))`.
- Re-apply styles when any of `store.revision`, `store.filter`, `store.selection`, `store.hover`,
  `store.mapBaseStyle` changes (`.onChange(of:)` on a `Hashable` key struct). `store.cameraRequest`
  → `engine.setCamera(preset, animated: true)` then `store.cameraRequest = nil`.
  `store.lastStatusChange` → `engine.animateStatusChange` then clear.
- Delegate (a small `@MainActor final class Coordinator: MapEngineDelegate`): `didSelect` →
  `store.select(id, showInspector: true)` (nil → `store.selection = nil`); `didHover` → `store.hover`
  + tooltip position; `cameraDidChange` → save to UserDefaults; `didFinishLoading(ok:false)` → banner.
- Overlays (ZStack over `MapHostView`): legend **top-left** (toggle `store.legendShown`; continuous
  ramp bar 1…100 with ticks at 25/50/75 + band symbols, status key, lift/boundary key; hovering a band
  temporarily dims others by pushing a preview filter — V1 may skip the hover-preview), camera chips
  bottom-right (`Overview · CA · NV · Mott/Killebrew`), "Trails © OpenStreetMap contributors (ODbL)"
  10 pt above the chips, hover tooltip (`name · band symbol · rating`, `length · vert · avg grade`)
  after 150 ms at the hover point, offline banner top-center. Bottom-left 180×40 pt stays empty
  (Apple attribution). Toast is rendered by RootView (WP4), not here.
- Toolbar items for the Map section (`.toolbar` inside MapScreen): Camera menu, Base style menu
  (disabled entries for unsupported styles), Filter menu (shared `FilterMenu` from WP4 if present —
  if not yet available, a minimal area/band/status menu bound to `store.filter`), Legend toggle, Fit.
  Keyboard: `Cmd+0`, `Cmd+Opt+1/2/3`, `Cmd+Shift+F`, `Cmd+Shift+L` live in `AppCommands` (WP4) and
  only set `store.cameraRequest` / `store.legendShown`, so MapScreen reacts to the store.

### WP3.7 Verify (screenshots are the evidence; read every PNG)
```sh
swift build -c release
S=/private/tmp/claude-501/-Users-calebsuh/810bede8-95e3-4752-88a3-c504cfe6ddb2/scratchpad/wp3shots; mkdir -p $S/ud
for cam in overview california nevada mottKillebrew; do
  HT_USERDATA_DIR=$S/ud HT_SCREENSHOT=$S/$cam.png HT_SCREENSHOT_DELAY=10 HT_SECTION=map HT_CAMERA=$cam \
  timeout 60 .build/arm64-apple-macosx/release/SkiLo; done
HT_USERDATA_DIR=$S/ud HT_SCREENSHOT=$S/selected_done.png HT_SCREENSHOT_DELAY=10 HT_SECTION=map \
  HT_CAMERA=california HT_SELECT=t-gunbarrel HT_MARK_DONE=t-gunbarrel HT_BUCKET=t-the-face \
  timeout 60 .build/arm64-apple-macosx/release/SkiLo
HT_USERDATA_DIR=$S/ud HT_SCREENSHOT=$S/outline.png HT_SCREENSHOT_DELAY=6 HT_SECTION=map HT_BASE_STYLE=outline \
  timeout 60 .build/arm64-apple-macosx/release/SkiLo
tools/run_tests.sh --filter "Picking|CameraPresets"
```
Also measure: log `apply(styles:)` time and pick time; `/usr/bin/time -l` max RSS for the
california shot (target ≤ 1.1 GB).

### WP3.8 Acceptance
- Overview: 3D relief, all trails coloured by the ramp with white casing, lifts, boundary, legend
  top-left, chips bottom-right, Apple logo visible bottom-left, no HUD text.
- California at 60° (or the pitch you settled on): no gray grid; Gunbarrel selected shows glow +
  label; after `HT_MARK_DONE` the line is desaturated/dimmed with a green check badge; The Face has
  the yellow casing + star.
- Outline: flat map, trails visible.
- A synthetic click test like the spike's (`sendSyntheticClick` through `NSWindow.sendEvent` at a
  projected midpoint) selecting the expected trail is **strongly recommended** (reuse
  `spikes/mapkit/Shared.swift`) — wire it as `HT_CLICK=t-gunbarrel` inside `MapScreen` behind
  `DevHooks.isScripted` if you add it; report PASS/FAIL.
- Tests green; timings and RSS reported; the two §WP3.1 answers recorded.

---

## WP4 — Screens A: shell, trails, inspector, settings, onboarding, menus (`wp4-screens-a`)

### Files
```
Sources/SkiLo/Views/Shell/RootView.swift            REPLACES stub
Sources/SkiLo/Views/Shell/SidebarView.swift         REPLACES stub
Sources/SkiLo/Views/Shell/MiniProgressCard.swift    REPLACES stub
Sources/SkiLo/Views/Shell/FilterMenu.swift          NEW (shared filter control; Map/Trails/Bucket toolbars use it)
Sources/SkiLo/Views/Trails/TrailsScreen.swift       REPLACES stub (+ helpers in Views/Trails/)
Sources/SkiLo/Views/Inspector/TrailInspector.swift  REPLACES stub
Sources/SkiLo/Views/Inspector/ElevationProfileChart.swift  REPLACES stub
Sources/SkiLo/Views/Inspector/RatingBreakdownView.swift    REPLACES stub
Sources/SkiLo/Views/Inspector/OverridePopover.swift        REPLACES stub
Sources/SkiLo/Views/Settings/SettingsView.swift     REPLACES stub
Sources/SkiLo/Views/Onboarding/OnboardingSheet.swift REPLACES stub
Sources/SkiLo/Views/Shared/*.swift                  polish allowed; keep initializers
Sources/SkiLo/App/AppCommands.swift                 REPLACES stub
Tests/SkiLoTests/FilterTests.swift                  NEW (TrailFilter.matches + Format)
```

### WP4.1 `RootView` (UX §1.1–§1.3)
`NavigationSplitView(sidebar: SidebarView, detail: content)` `.navigationSplitViewStyle(.balanced)`;
content switches on `store.section` (`MapScreen`, `TrailsScreen`, `BucketScreen`, `ProgressScreen`,
`LogScreen`); `.inspector(isPresented: $store.inspectorShown) { TrailInspector() }` with
`.inspectorColumnWidth(min: 320, ideal: 360, max: 480)`; `.searchable(text: $store.filter.searchText)`;
toolbar inspector toggle; `.sheet(item: $store.logRunRequest) { LogRunSheet(request: $0) }`;
`.sheet(isPresented: $store.showOnboarding) { OnboardingSheet() }`; `.alert` for `store.pendingAlert`
if WP2 added it (guard with `if let`); toast overlay top-right via `ToastView` with auto-dismiss;
`.onAppear { store.undoManager = undoManager }` using `@Environment(\.undoManager)`; `Esc` clears
selection (`.onKeyPress(.escape)`); `Cmd+N` disabled in `AppCommands` (`CommandGroup(replacing: .newItem) {}`).
Section + inspector state come from the store (persisted by WP2 in UserDefaults).

### WP4.2 `SidebarView` + `MiniProgressCard`
Five rows with symbols and `Cmd+1…5` (shortcuts in `AppCommands` set `store.section`), bucket badge
count = `store.bucketPending.count`, footer card: skill `store.skill.rounded`, progress bar
`doneCount / catalog.trails.count`, "41/126 done"; click → `.progress`.

### WP4.3 `TrailsScreen` (UX §3)
`Table(store.visibleTrails sorted, selection: $selected, sortOrder:)` with the 16 columns (default
visibility per the spec; visibility stored in `@AppStorage("trails.columns")` as a JSON `[String]`),
status bar line, group-by (None / Area / Band — implement as a picker that sorts and shows section
headers via a `List` fallback if `Table` sections are awkward; grouping is P0 but "None" must work
perfectly), toolbar Mark Done / Bucket buttons (bulk over the selection, `store.markDone(ids,
backfilled: false)`), context menu (Mark Done/Not Done, Add/Remove Bucket, Log Run…, Show on Map,
Override Rating…, Copy Name), single click → `store.select(id, showInspector: false)`, double-click /
Return → `store.select(id, showInspector: true)`.

### WP4.4 `TrailInspector` (UX §2.6, exact layout)
Header (name, `BandSymbol`, area · subArea), `RatingPill`, OSM/grooming/gladed line, override line,
status segmented picker bound to a derived `Binding<TrailStatus>` that calls `markDone` /
`markNotDone` / `addToBucket` / `removeFromBucket`, "Log Run…" button → `store.requestLogRun`, stats
grid (`Format` with `store.userData.profile.units`), `ElevationProfileChart` (Swift Charts
`AreaMark` + `LineMark`, x in mi/km, y ft/m, gradient by sample `gradePct` through `Ramp`, hover rule
with callout), `RatingBreakdownView` (rows from `trail.rating.components`, bars sign-coloured, Total,
override row + Reset), "Your history" (`timesSkied`, first done, last 5 runs from `store.userData.runLog`
filtered by trail), Notes `TextEditor` debounced 600 ms → `store.setNotes`, footer "OSM ways … · ODbL".
Empty state when `store.selection == nil`. `OverridePopover` (`Cmd+Shift+R`): slider 1–100 on a ramp
track, live band symbol, required note, Save → `store.setOverride`.

### WP4.5 `SettingsView` (UX §1.7, General + Data + About tabs only)
Units picker (→ `store.units`), default section, "Reset all user data…" with confirmation →
`store.resetAllUserData()`, data folder path + "Reveal in Finder", Export/Import buttons (call
`ExportImport` via `NSSavePanel`/`NSOpenPanel`; Import = Replace with confirmation; guard on WP2's
implementation existing — it compiles against the stub regardless), About with OSM/ODbL and Apple
Maps attribution text.

### WP4.6 `OnboardingSheet` (UX §1.8)
Slider 1–100 with the ramp underneath, anchor labels from the catalog (`t-maggie-s`,
`t-olympic-downhill`, `t-ellie-s`, `t-gunbarrel`, `t-snake-eyes` → their `rating.total`), optional
backfill checkboxes (all greens / all blues by `Band.of(rating.total)`), Skip and Start →
`store.completeOnboarding(selfAssessed:backfill:)`.

### WP4.7 `AppCommands` (UX §1.5–§1.6)
All menus and shortcuts listed in the spec; Trail-menu items disabled when `store.selection == nil`;
`Cmd+D` toggles done; `Cmd+B` toggles bucket; `Cmd+L` → `requestLogRun`; `Cmd+Shift+R` → sets
`store.overridePopoverRequested = true` (add this `var` to AppStore only if WP2 agrees; otherwise use a
`@FocusedValue` — simplest: add a `Notification.Name.htOverrideRating` posted by the command and observed by the inspector);
camera shortcuts → `store.requestCamera`; `Cmd+Shift+L` → `store.legendShown.toggle()`;
`Cmd+Shift+E/I` → export/import panels; Help → "Data & Attribution" opens a small window/sheet.

### WP4.8 `ToastView`
Capsule top-right, `.regularMaterial`, symbol + text + action buttons, auto-dismiss after
`toast.autoDismissSeconds` (Task + cancellation), slide+fade, newest wins.

### WP4.9 Verify
```sh
swift build && tools/run_tests.sh --filter Filter
S=…/wp4shots; for sec in trails bucket progress log; do HT_USERDATA_DIR=$S/ud HT_SCREENSHOT=$S/$sec.png HT_SCREENSHOT_DELAY=4 HT_SECTION=$sec HT_SELECT=t-gunbarrel timeout 40 .build/debug/SkiLo; done
HT_USERDATA_DIR=$S/ud HT_SCREENSHOT=$S/inspector_done.png HT_SCREENSHOT_DELAY=6 HT_SECTION=trails HT_SELECT=t-gunbarrel HT_MARK_DONE=t-gunbarrel timeout 40 .build/debug/SkiLo
```
(Other sections may still show WP5 stubs; that is fine — the shell, table, inspector and toast are what you verify.)

### WP4.10 Acceptance
Screenshots show: sidebar with 5 sections + mini card; Trails table with ≥ 10 columns, sortable
(sort by rating descending visible in a shot), status glyphs; Inspector with pill, segmented status,
stats grid, elevation chart with data, rating breakdown rows, notes; toast after `HT_MARK_DONE`
with Undo; onboarding sheet shot (`HT_SKIP_ONBOARDING` unset + fresh `HT_USERDATA_DIR`); settings
window shot. FilterTests green.

---

## WP5 — Screens B + progression: bucket, log, progress, engines (`wp5-screens-b`)

### Files
```
Sources/SkiLo/Progression/DefaultProgressionEngine.swift  REPLACES stub
Sources/SkiLo/Progression/Milestones.swift               REPLACES stub
Sources/SkiLo/Views/Bucket/BucketScreen.swift            REPLACES stub
Sources/SkiLo/Views/Bucket/AddTrailPopover.swift         REPLACES stub
Sources/SkiLo/Views/Log/LogScreen.swift                  REPLACES stub
Sources/SkiLo/Views/Log/LogRunSheet.swift                REPLACES stub
Sources/SkiLo/Views/Log/EditDaySheet.swift               REPLACES stub
Sources/SkiLo/Views/Progress/ProgressScreen.swift        REPLACES stub (+ chart helpers in Views/Progress/)
Tests/SkiLoTests/ProgressionTests.swift                  NEW
Tests/SkiLoTests/MilestoneTests.swift                    NEW
```

### WP5.1 `DefaultProgressionEngine` (UX §7.5 + DESIGN §6.5)
- `skillHistory`: one `SkillPoint` per ski day (plus the seed at `profile.startDate` =
  `selfAssessedStart`), computed walk-forward: for day *d*, runs within the trailing 60 days, each run
  `e = clamp(rating × conditions.multiplier, 1, 100)`, `m = e + 4·(confidence − 3)`, weight
  `0.5^(ageDays/30)`; raw = weighted 80th percentile of `m` (if ≥ 3 runs) else `max(m) − 5` (if
  1–2) else `selfAssessedStart`; `skill = max(raw, 0.9 × previous)`; clamp 1…100; interval
  `±(10 − min(basisRuns, 7))`. Runs on trails with `backfilled` states still count (only streaks
  exclude backfills); entries whose trail id is missing from `ratings` are ignored.
- `currentSkill`: last point or the seed.
- `readiness`: `delta = rating − round(skill)`; `≤ −8 belowYou`, `≤ 7 ready`, `≤ 15 stretch`, else
  `bigStretch`; then the gate rule: `modifiers.gated && skill < 58` → `bigStretch` with reason
  "behind a gate — build to 58 first"; `modifiers.hikeTo && skill < 65` → `bigStretch`, "hike-to —
  build to 65 first". Reasons otherwise: "right at your level (skill 58)", "a 6-point stretch — try it
  on a soft day", "big stretch (+14)", "below your level".
- `readyFor`: not-done trails with `.ready`, sorted by `|delta − 3|` then name, `limit`.
- `suggestedNext`: pending bucket ids (status `.bucket`) with `.ready`, lowest `delta ≥ 0` first
  (else highest negative), else the smallest `stretch`; nil if none.

### WP5.2 `MilestoneRegistry` (UX §7.6)
All 14 families: `first.green/blue/black/doubleBlack`, `all.greens/blues/blacks/doubleBlacks`
(fraction), `trail.gunbarrel`, `trail.theFace`, `area.mottCanyon`, `area.mottComplete` (fraction),
`area.killebrew`, `area.bothStates` (a ski day with runs in CA and NV), `first.glade`, `first.moguls`,
`count.25/50/100` (fraction), `days.10` (fraction), `half` (fraction). Bands use `context.ratings`
(effective). Titles/symbols as in the spec table.

### WP5.3 `BucketScreen` (UX §4) — `List` with `.onMove` → `store.moveBucket`, ring, suggested-next
card, readiness chips, inline Done, `⋯` menu, Crossed Off section (strike-through), `AddTrailPopover`
(search + multi-select + Add → `store.addToBucket`), empty state with `readyFor(limit: 5)`, toolbar
Sort (view-only) and Show crossed-off toggle.

### WP5.4 `LogScreen`, `LogRunSheet`, `EditDaySheet` (UX §6)
Day sections from `store.skiDays` (title, conditions, run count, total vert = Σ `trail.stats.verticalDropM`,
max rating), rows (time, trail name → select, band + rating, conditions chip × multiplier, confidence
stars, notes, NEW tag), context menu (Edit…, Duplicate, Show on Map, Delete), search by name/notes.
`LogRunSheet(request:)`: trail picker (searchable, prefilled), date+time, conditions chips, confidence
1–5 with captions, notes, "Mark trail as done" (default on if not done), Log → `store.logRun(entry,
alsoMarkDone:)` or `store.updateRun` when `request.existing != nil`; on dismiss `store.logRunRequest = nil`.

### WP5.5 `ProgressScreen` (UX §5)
Four stat tiles, skill line chart (`LineMark` + `AreaMark` low…high, `RuleMark` at 25/50/75, `PointMark`
per ski day, hover callout), histogram by rating decile (done vs total, click → set
`store.filter.ratingRange` + `section = .trails`), counts by area/band + total vert, streaks (days on
snow; new-trail streak excluding backfilled), "Ready for you" (5) with Add-all-to-bucket, milestone
grid (unlocked with date / locked with fraction). Toolbar: season + range pickers (filter the log by
date; "All time" default when the log spans < 1 season).

### WP5.6 Tests
`ProgressionTests`: deterministic synthetic logs — no runs → seed; 1 run → `max − 5`; ≥ 3 runs →
80th percentile check against a hand-computed value; decay (a run 60 days old weighs 0.25); smoothing
floor `0.9 × prev`; readiness cut points at −8/7/15 and the gate rule; `readyFor` ordering;
`suggestedNext` picks the lowest non-negative ready bucket item. `MilestoneTests`: each milestone
achieved/locked on constructed `UserData` against the bundled catalog (e.g. mark all `.green`
effective-band trails → `all.greens` achieved; one CA + one NV run on the same day → `area.bothStates`).

### WP5.7 Verify / acceptance
`tools/run_tests.sh --filter "Progression|Milestone"` green. Screenshots (`HT_SECTION=bucket/log/progress`
with `HT_BUCKET=t-ellie-s,t-gunbarrel HT_MARK_DONE=t-big-dipper`) show: bucket list with ring,
chips, suggested next, crossed-off section; log with one day section (log a run through
`HT_LOG_RUN=t-big-dipper` if you add that hook to `DevHooks` — you may not edit DevHooks; instead
pre-write a `userdata.json` with one run into `HT_USERDATA_DIR` using `UserDataStore.encode` from a
tiny test, or hand-write the JSON); progress with the four tiles, a chart with ≥ 2 points, histogram,
milestones grid.

---

## WP6 — Integration (`wp6-integration`, sequential, last)

### Files
May edit **any** file to resolve compile conflicts and wire loose ends; every edit is listed in the
report with the reason. Creates `docs/ACCEPTANCE.md`, updates `README.md` (usage, data provenance,
attribution, dev hooks), optionally `assets/AppIcon.icns` (UX §8.4; `iconutil` is in CLT).

### WP6.1 Steps
1. Confirm all WP1–WP5 deliveries are in the main tree (`ls` the file lists above). `swift build`;
   fix cross-package errors minimally; prefer fixing the consumer over changing a contract.
2. `tools/build_app.sh sync-data` (regenerate the catalog), `tools/run_tests.sh` (all suites green — look for the `✔ Test run with N tests` line).
3. `tools/build_app.sh` (release .app) and `tools/build_app.sh verify`.
4. Acceptance walk-through with the **assembled app** (`build/SkiLo.app/Contents/MacOS/SkiLo -ApplePersistenceIgnoreState YES`
   with `HT_*`), fresh `HT_USERDATA_DIR`, in this order, one screenshot each:
   a. launch, no env except `HT_SCREENSHOT`+`HT_USERDATA_DIR` and `HT_SKIP_ONBOARDING` unset → onboarding sheet;
   b. `HT_SECTION=map HT_CAMERA=overview` → 3D terrain, 126 coloured trails, legend, chips, Apple logo;
   c. `HT_SECTION=map HT_CAMERA=california HT_SELECT=t-gunbarrel` → selected glow + inspector;
   d. same + `HT_MARK_DONE=t-gunbarrel` → done style + check badge + toast; verify `userdata.json` in
      `HT_USERDATA_DIR` contains `"t-gunbarrel"` with `"status" : "done"`;
   e. relaunch with the same `HT_USERDATA_DIR`, `HT_SECTION=bucket` with `HT_BUCKET=t-the-face` →
      Gunbarrel persisted as done (visible in Trails shot f), The Face in the bucket list;
   f. `HT_SECTION=trails` sorted table; g. `HT_SECTION=progress`; h. `HT_SECTION=log`;
   i. `HT_BASE_STYLE=outline` map.
   Also run the synthetic click if WP3 provided `HT_CLICK`.
5. Memory/time: `/usr/bin/time -l` on shot (c); report max RSS and time-to-screenshot.
6. Write `docs/ACCEPTANCE.md`: the P0 checklist from UX §9.1 with pass/fail, screenshot paths,
   test counts, known gaps.
7. Launch through LaunchServices once (`tools/build_app.sh run`, then `pkill -TERM -x SkiLo`)
   and confirm `lsappinfo` saw it, to prove the bundle works outside the headless path.

### WP6.2 Acceptance (V1 done)
- All tests green; release build + signed .app; every walk-through shot viewed and described.
- State persists across relaunch (d → e).
- No file in the tree is a WP0 stub any more (`grep -rn "pending" Sources/ | grep -i "WP"` is empty).
- README documents build, data regeneration, attribution (Apple Maps, OSM ODbL, AWS terrain tiles),
  the dev hooks, and that tests run via `tools/run_tests.sh` (bare `swift test` is a no-op under CLT). No git commit (the orchestrator commits).

---

## Appendix A — Cross-package dependency summary

| Consumer | Uses from | Symbols |
|---|---|---|
| WP3 Map | WP0 | `MapEngine*`, `Trail`, `GeoCoordinate`, `GeoBounds`, `RGBA`, `AppStore` (Views/Map only), `TrailStyleBuilder.styles(for:)` (stub OK) |
| WP4 Screens A | WP0 | `AppStore` API, `Trail`, `RatingBreakdown.components`, `Format`, Shared views, `ExportImport`, `LogRunRequest`, `MapScreen()` / `BucketScreen()` / `LogScreen()` / `ProgressScreen()` / `LogRunSheet(request:)` initializers |
| WP5 Screens B | WP0 | `AppStore` API, `ProgressionEngine`, `Milestone*`, `SkiDay`, `Conditions`, Shared views |
| WP2 Core | WP0 | everything in Models, `MilestoneRegistry.newlyAchieved` (stub OK), `DefaultProgressionEngine` (stub OK) |
| WP1 Data | WP0 | `RatingInput`, `CuratedModifiers`, `RatingBreakdown`, `CatalogLoader`, `TestPaths` |

Nothing in WP1–WP5 depends on another WP1–WP5 package at compile time; everything compiles
against WP0's stubs, and WP6 verifies the real combination.

## Appendix B — Time budget (guidance, not a promise)

WP0 30–45 min · WP1 45–60 min · WP2 60–90 min · WP3 90–150 min · WP4 90–150 min · WP5 90–120 min ·
WP6 45–60 min. The map (WP3) and the two screen packages are the long poles; start them first.

## Appendix C — Verified WP0 view/shared stub sources

Extracted from the architect's compile-checked scratch tree (built with 0 errors, tests 4/4, app launched).
Copy verbatim into `Sources/SkiLo/<path>`.

#### `App/AppCommands.swift`
```swift
import SwiftUI
struct AppCommands: Commands {
    let store: AppStore
    init(store: AppStore) { self.store = store }
    var body: some Commands { EmptyCommands() }
}
```

#### `Map/MapHostView.swift`
```swift
import SwiftUI
import AppKit

struct MapHostView: NSViewRepresentable {
    let engine: any MapEngine
    func makeNSView(context: Context) -> NSView { engine.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

#### `Views/Shell/RootView.swift`
```swift
import SwiftUI
struct RootView: View {
    init() {}
    var body: some View { MapScreen() }
}
```

#### `Views/Shell/SidebarView.swift`
```swift
import SwiftUI
struct SidebarView: View {
    init() {}
    var body: some View { Text("SidebarView — WP4 pending") }
}
```

#### `Views/Shell/MiniProgressCard.swift`
```swift
import SwiftUI
struct MiniProgressCard: View {
    init() {}
    var body: some View { Text("MiniProgressCard — WP4 pending") }
}
```

#### `Views/Map/MapScreen.swift`
```swift
import SwiftUI
struct MapScreen: View {
    @Environment(AppStore.self) private var store
    @State private var engine: any MapEngine = MapKitEngine()
    init() {}
    var body: some View {
        ZStack(alignment: .topLeading) {
            MapHostView(engine: engine).ignoresSafeArea()
            Text("MapScreen — WP3 pending · \(store.catalog.trails.count) trails").padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        }
    }
}
```

#### `Views/Map/MapOverlays.swift`
```swift
import SwiftUI
struct MapOverlays: View {
    let engine: any MapEngine
    let viewSize: CGSize
    init(engine: any MapEngine, viewSize: CGSize) { self.engine = engine; self.viewSize = viewSize }
    var body: some View { EmptyView() }
}
```

#### `Views/Trails/TrailsScreen.swift`
```swift
import SwiftUI
struct TrailsScreen: View {
    init() {}
    var body: some View { Text("TrailsScreen — WP4 pending") }
}
```

#### `Views/Inspector/TrailInspector.swift`
```swift
import SwiftUI
struct TrailInspector: View {
    init() {}
    var body: some View { Text("TrailInspector — WP4 pending") }
}
```

#### `Views/Inspector/ElevationProfileChart.swift`
```swift
import SwiftUI
struct ElevationProfileChart: View {
    let trail: Trail; let units: Units
    init(trail: Trail, units: Units) { self.trail = trail; self.units = units }
    var body: some View { Text("ElevationProfileChart — WP4 pending") }
}
```

#### `Views/Inspector/RatingBreakdownView.swift`
```swift
import SwiftUI
struct RatingBreakdownView: View {
    let breakdown: RatingBreakdown; let override: Int?; let note: String?
    init(breakdown: RatingBreakdown, override: Int?, note: String?) { self.breakdown = breakdown; self.override = override; self.note = note }
    var body: some View { Text("RatingBreakdownView — WP4 pending") }
}
```

#### `Views/Inspector/OverridePopover.swift`
```swift
import SwiftUI
struct OverridePopover: View {
    let trailID: Trail.ID; @Binding var isPresented: Bool
    init(trailID: Trail.ID, isPresented: Binding<Bool>) { self.trailID = trailID; self._isPresented = isPresented }
    var body: some View { Text("OverridePopover — WP4 pending") }
}
```

#### `Views/Settings/SettingsView.swift`
```swift
import SwiftUI
struct SettingsView: View {
    init() {}
    var body: some View { Text("SettingsView — WP4 pending") }
}
```

#### `Views/Onboarding/OnboardingSheet.swift`
```swift
import SwiftUI
struct OnboardingSheet: View {
    init() {}
    var body: some View { Text("OnboardingSheet — WP4 pending") }
}
```

#### `Views/Bucket/BucketScreen.swift`
```swift
import SwiftUI
struct BucketScreen: View {
    init() {}
    var body: some View { Text("BucketScreen — WP5 pending") }
}
```

#### `Views/Bucket/AddTrailPopover.swift`
```swift
import SwiftUI
struct AddTrailPopover: View {
    @Binding var isPresented: Bool
    init(isPresented: Binding<Bool>) { self._isPresented = isPresented }
    var body: some View { Text("AddTrailPopover — WP5 pending") }
}
```

#### `Views/Log/LogScreen.swift`
```swift
import SwiftUI
struct LogScreen: View {
    init() {}
    var body: some View { Text("LogScreen — WP5 pending") }
}
```

#### `Views/Log/LogRunSheet.swift`
```swift
import SwiftUI
struct LogRunSheet: View {
    let request: LogRunRequest
    init(request: LogRunRequest) { self.request = request }
    var body: some View { Text("LogRunSheet — WP5 pending") }
}
```

#### `Views/Log/EditDaySheet.swift`
```swift
import SwiftUI
struct EditDaySheet: View {
    let dayKey: String; @Binding var isPresented: Bool
    init(dayKey: String, isPresented: Binding<Bool>) { self.dayKey = dayKey; self._isPresented = isPresented }
    var body: some View { Text("EditDaySheet — WP5 pending") }
}
```

#### `Views/Progress/ProgressScreen.swift`
```swift
import SwiftUI
struct ProgressScreen: View {
    init() {}
    var body: some View { Text("ProgressScreen — WP5 pending") }
}
```

#### `Views/Shared/ToastView.swift`
```swift
import SwiftUI
struct ToastView: View {
    let toast: Toast; let dismiss: () -> Void
    init(toast: Toast, dismiss: @escaping () -> Void) { self.toast = toast; self.dismiss = dismiss }
    var body: some View { Text(toast.text) }
}
```

#### `Views/Shared/RatingPill.swift`
```swift
import SwiftUI
struct RatingPill: View {
    let rating: Int; let isOverride: Bool; let size: Font
    init(rating: Int, isOverride: Bool = false, size: Font = .title2) { self.rating = rating; self.isOverride = isOverride; self.size = size }
    var body: some View {
        let bg = Ramp.color(for: rating)
        HStack(spacing: 2) {
            Text("\(rating)").font(size.weight(.bold)).monospacedDigit()
            if isOverride { Image(systemName: "pencil").font(.caption) }
        }
        .foregroundStyle(Ramp.textColor(on: bg).color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(bg.color, in: Capsule())
    }
}
```

#### `Views/Shared/BandSymbol.swift`
```swift
import SwiftUI
struct BandSymbol: View {
    let band: Band
    init(band: Band) { self.band = band }
    var body: some View {
        HStack(spacing: -2) {
            Image(systemName: band.symbolName)
            if band == .doubleBlack { Image(systemName: band.symbolName) }
        }
        .foregroundStyle(color)
    }
    private var color: Color {
        switch band { case .green: Color(RGBA(hex: "#34C759").nsColor); case .blue: Color(RGBA(hex: "#0A84FF").nsColor); case .black, .doubleBlack: .primary }
    }
}
```

#### `Views/Shared/StatusGlyph.swift`
```swift
import SwiftUI
struct StatusGlyph: View {
    let status: TrailStatus
    init(status: TrailStatus) { self.status = status }
    var body: some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Ramp.doneGreen.color)
        case .bucket: Image(systemName: "star.fill").foregroundStyle(Ramp.bucketYellow.color)
        case .notDone: Image(systemName: "circle").foregroundStyle(.clear)
        }
    }
}
```

#### `Views/Shared/ReadinessChip.swift`
```swift
import SwiftUI
struct ReadinessChip: View {
    let readiness: Readiness
    init(readiness: Readiness) { self.readiness = readiness }
    var body: some View {
        Text(label).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
    private var label: String {
        switch readiness.kind {
        case .ready: "ready"
        case .stretch: "stretch +\(readiness.delta)"
        case .bigStretch: "big stretch +\(readiness.delta)"
        case .belowYou: "below you"
        }
    }
    private var color: Color {
        switch readiness.kind {
        case .ready: RGBA(hex: "#34C759").color
        case .stretch: RGBA(hex: "#FF9F0A").color
        case .bigStretch: RGBA(hex: "#FF453A").color
        case .belowYou: RGBA(hex: "#8E8E93").color
        }
    }
}
```

#### `Views/Shared/Format.swift`
```swift
import Foundation
enum Format {
    private static let num: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()
    static func length(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: String(format: "%.1f mi", m / 1609.344); case .metric: String(format: "%.1f km", m / 1000) }
    }
    static func elevation(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: (num.string(from: NSNumber(value: m * 3.28084)) ?? "") + " ft"; case .metric: (num.string(from: NSNumber(value: m)) ?? "") + " m" }
    }
    static func vert(_ m: Double, _ u: Units) -> String { elevation(m, u) }
    static func grade(_ pct: Double) -> String { String(format: "%.0f%%", pct) }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}
```
