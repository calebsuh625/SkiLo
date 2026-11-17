# HeavenlyTracker — Architecture Design

Status: v1 decision document, 2026-11-01. Author: architect agent. Audience: the parallel build
agents (see `docs/BUILD_PLAN.md`) and the orchestrator.

This document decides the map engine, fixes the module layout, defines the data flow, the
abstract `MapEngine` interface, persistence, and the **final JSON catalog schema** the app consumes.
Where the UX spec (`docs/UX_SPEC.md`), the rating method (`docs/RATING_METHOD.md`), the data pipeline
(`tools/build_trails.py` → `data/trails.json`) and the build system (`Package.swift`, `Makefile`)
disagree, §6 states the resolution; this document wins over all of them.

## 0. Inputs verified (read on 2026-11-01)

| File | Verified |
|---|---|
| `docs/UX_SPEC.md` (1,145 lines) | read in full; §2.7 `MapEngine`, §7 data model, §8 ramp, §9 scope |
| `docs/RATING_METHOD.md` (680 lines) | read in full; §3 formula, §3.10 Swift, §4 anchors, Appendix A/B |
| `data/trails.json` (1.25 MB) | 160 trails (126 named + 34 unnamed), schema inspected with jq; `stats.p90_grade_pct`, `segments[].coords` as `[lon,lat,ele]`, `profile` as `[d,ele]` every 25 m |
| `data/curated_modifiers.json` | 90 entries keyed by exact OSM name; every key exists in `trails.json` (comm diff empty) |
| `data/calibration_anchors.json` | 126 entries (`name, expected_rating, target, tol, inputs`), 29 with targets; all names exist in `trails.json` |
| `data/lifts.json` | 23 lifts (18 chair, 1 gondola, 1 cable_car, 2 magic_carpet, 1 rope_tow) + 12 stations |
| `data/boundary.json` | one closed outer ring, 338 vertices |
| `data/dem/{heavenly_dem.f32,heavenly_dem.png,dem_meta.json}` | present (12.8 MB / 2.3 MB) |
| `Package.swift`, `Makefile`, `tools/build_app.sh`, `tools/Info.plist`, `README.md` | read; tools-version 6.0, macOS 15, `.swiftLanguageMode(.v5)`, CLT-only test flags |
| `Sources/HeavenlyTracker/*.swift` (5 files), `Tests/HeavenlyTrackerTests/SmokeTests.swift` | read |
| `spikes/mapkit/{Shared.swift,MKSpike.swift,README.md}` | read; `pickTrail` / `pointSegmentDistance` reused in design |
| Spike reports + judge panel (3 lenses) | in the task input |

Counts that matter: **126 named trails** (not 127 — `jq unique` on names gives 126; the brief's 127
was wrong), 34 unnamed connector ways, 23 lifts, 6,559 resampled trail vertices, 3,931 profile
samples. Toolchain: Swift 6.3.2 via `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, no
`xcodebuild`, no XCTest (swift-testing only), Python 3 with numpy + Pillow at
`/Users/calebsuh/miniconda3/bin/python3`. **Tests run through `tools/run_tests.sh`, not `swift test`**:
under CLT `swift test` builds the bundle and silently runs nothing (verified; BUILD_PLAN §0.1), so the
architect added `tools/testhost/main.swift` (a dlopen host for swift-testing) and `tools/run_tests.sh`.

---

## 1. Map engine decision

### 1.1 Panel scores

| Lens | MapKit (MKMapView, realistic elevation) | MapLibre GL JS in WKWebView | Custom SceneKit mesh | Lens recommendation |
|---|---:|---:|---:|---|
| Rendering fidelity & delight | **8** | 7.5 | 4.5 | MapKit |
| Effort, maintainability, risk | **9** | 6 | 5 | MapKit |
| Robustness, offline, performance | 6 | 5.5 | **8** | SceneKit |
| **Sum** | **23** | 19 | 17.5 | |

### 1.2 Decision

**V1 ships one engine: Apple MapKit, `MKMapView` (AppKit) inside an `NSViewRepresentable`, with
`MKHybridMapConfiguration(elevationStyle: .realistic)` (or `MKImageryMapConfiguration(elevationStyle:
.realistic)` if it is verified to render terrain — see §8.4), `MKPolyline` overlays with cached
`MKPolylineRenderer`s, screen-space nearest-segment picking, and `MKAnnotationView` badges**, wrapped
as `MapKitEngine` behind the engine-agnostic `MapEngine` protocol (§7). Not the SwiftUI `Map`
variant: it is 4–12× slower to project, has no render-complete callback, no z-order control, and its
`Map(selection:)` does not fire for polylines (spike log `out/run_nativesel.log`).

Why MapKit wins despite losing the offline lens:

1. Two of three lenses pick it, with the highest total (23 vs 19 vs 17.5).
2. It is the only option whose imagery and line registration already look finished (median 4 pt
   convert-vs-render offset, lines on the cut corridors at 2.5 km and 11 km), with zero third-party
   code, no CDN, no JS bridge, no deprecated framework, 2 s compiles, first-party trackpad gestures.
3. The user said the app is "used at home mostly"; offline is a nice-to-have, not a V1 requirement.
   The DEM pipeline that the **rating** needs is already done offline (`data/dem`) and never touches
   the renderer, so MapKit's lack of elevation queries costs the product nothing.
4. The remaining engineering is ~300 lines of first-party API (`spikes/mapkit/MKSpike.swift` +
   `Shared.swift` minus the harness); the production plan in §8 is essentially the spike with the
   panel's must-fix items applied.

Not chosen:

- **MapLibre/WKWebView**: the async JS bridge cannot implement the synchronous `project()` /
  `currentCamera()` the overlays need; WebKit suspends `requestAnimationFrame` when the window is
  occluded (3 of 9 unattended runs stalled); runtime CDN dependency; Esri imagery terms forbid
  caching; two-language debugging. Its styling richness does not pay for that.
- **SceneKit**: deprecated since WWDC25; the custom camera controller, labels with occlusion,
  chunked imagery, LOD and a licensable imagery pipeline are 2–3 engineer-weeks of custom rendering
  work that MapKit gives for free; the spike looked like a game prototype, not Heavenly.

### 1.3 What is kept from the other spikes (the only "hybrid" in V1)

| Piece | Used for | Scope |
|---|---|---|
| AWS terrarium DEM pipeline (`tools/build_trails.py`, `data/dem/*`) | all grade statistics behind the 1–100 rating | already done; renderer-independent |
| `MapEngine` protocol (UX spec §2.7, revised in §7) | keeps a second engine possible | V1 has exactly one implementation and **no engine picker** |
| MapLibre spike's offline-cache design + SceneKit spike's mesh/UV code | a future offline/winter-texture engine on RealityKit | **out of V1**; not started |

### 1.4 MapKit constraints and how V1 designs around them

| Measured constraint (spike / panel) | Design response |
|---|---|
| Pitch clamp by distance: ≥5 km → 35°, 3 km → 60°, ≤1.2 km → 70°; the whole resort needs 8–11 km | Camera presets revised (§8.6): Overview = 11 km / 35°; California, Nevada, Mott & Killebrew = 2.6–2.9 km / 60°. The engine reads back `mapView.camera` after every `setCamera` and reports the **actual** pitch; the UI never shows a pitch control, only presets + free trackpad gestures. |
| 1.4 GB RSS at 2.5 km / 60° (SwiftUI variant), ~0.95 GB footprint (MKMapView) | `cameraZoomRange` min centre distance **1,200 m**, max 30,000 m; `cameraBoundary` = catalog bounds padded 4 km. |
| Gray-grid sky when the horizon enters the frame | Pitch ≤ 60° and distance ≤ 2.9 km for the close presets keep the horizon out in the spike's framing; WP3 verifies by screenshot and lowers pitch/distance if the grid shows. |
| Apple street/POI labels clutter the mountain | `pointOfInterestFilter = .excludingAll`; prefer `MKImageryMapConfiguration` (no labels) if it renders terrain (§8.4); trail names come from our own selected-trail annotation. |
| `convert()` vs drawn line: median 4 pt, p90 11 pt, max 34 pt | Hit threshold **14 pt**, dedupe hits by `Trail.ID`, hover halo ≥ 14 pt. |
| No terrain occlusion information for overlays/annotations | Accepted for V1: `project()` returns nil only for off-screen points; badges may draw through ridges. Documented in `MapKitEngine`. |
| `.flat` elevation forces pitch 0 | `.outline` base style is flat/top-down by design; it is also the automatic fallback when `mapViewDidFailLoadingMap` fires (offline), so trail polylines are always visible. |
| Online only (geod); no offline API | `.offline` capability not advertised. Load failure → banner "Map imagery unavailable (offline?) — showing outline" + `.outline`. |
| Native polyline selection unsupported | Custom picking (§8.3), reusing the spike's pure `pickTrail` math. |
| Apple Maps logo/legal link must stay visible (bottom-left of the view) | Legend moves to **top-left**, camera chips bottom-right, toast top-right; nothing is drawn over the bottom-left 180×40 pt. OSM ODbL attribution line sits above the camera chips. |
| Summer imagery, no custom textures | Accepted. "Terrain" base style = `MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)`. |

---

## 2. Module layout

One SwiftPM **executable target** `HeavenlyTracker` (the existing `Package.swift` is kept: tools
6.0, macOS 15, `.swiftLanguageMode(.v5)`, resources `.copy("Resources")`, CLT test flags). The UX
spec's separate `HeavenlyCore` library target is **not** used: a second target would need
`public` on every type and complicates `@testable import`; folder discipline gives the same layering.
Tests are `Tests/HeavenlyTrackerTests` with `import Testing` and `@testable import HeavenlyTracker`
(already proven to work by the build agent).

```
HeavenlyTracker/
  Package.swift                      unchanged
  Makefile, tools/build_app.sh       sync-data now runs tools/build_catalog.py (WP1); test → tools/run_tests.sh (WP0)
  tools/run_tests.sh, tools/testhost/ swift-testing runner for CLT-only machines (architect, verified)
  tools/build_trails.py              existing pipeline (OSM + DEM → data/*.json), untouched
  tools/build_catalog.py             NEW: data/*.json + curated_modifiers + overrides → Resources/trails.json
  data/overrides/trail_overrides.json NEW: hand corrections (area, subArea, lift) applied last
  Sources/HeavenlyTracker/
    App/            HeavenlyTrackerApp.swift, AppDelegate.swift, AppCommands.swift (menus/shortcuts),
                    AppResources.swift, ResourceCheck.swift, SelfCapture.swift, DevHooks.swift
    Models/         GeoCoordinate.swift, Catalog.swift (TrailCatalog, Trail, Lift, Connector, enums),
                    UserData.swift, TrailFilter.swift, RGBA.swift          — pure value types, no logic
    Data/           CatalogLoader.swift      — decode bundled catalog, compute ratings, validate
    Rating/         RatingTypes.swift, DifficultyRating.swift             — pure, RATING_METHOD §3
    Style/          Ramp.swift, TrailStyleBuilder.swift                   — pure, UX §2.2 + §8.1
    Progression/    ProgressionTypes.swift, DefaultProgressionEngine.swift, Milestones.swift — pure
    Persistence/    UserDataStore.swift, Migrations.swift, ExportImport.swift — file IO only
    Store/          AppStore.swift (@Observable @MainActor), Toast.swift   — the single app state
    Map/            MapEngine.swift (protocol + types), MapSceneBuilder.swift, CameraPresets.swift,
                    Picking.swift, MapKitEngine.swift, MapHostView.swift  — engine; no AppStore import
    Views/
      Shell/        RootView.swift (NavigationSplitView), SidebarView.swift, MiniProgressCard.swift
      Map/          MapScreen.swift, MapOverlays.swift (legend, chips, tooltip, selected label)
      Trails/       TrailsScreen.swift (+ row/column helpers)
      Inspector/    TrailInspector.swift, ElevationProfileChart.swift, RatingBreakdownView.swift,
                    OverridePopover.swift
      Bucket/       BucketScreen.swift, AddTrailPopover.swift
      Log/          LogScreen.swift, LogRunSheet.swift, EditDaySheet.swift
      Progress/     ProgressScreen.swift (+ charts)
      Settings/     SettingsView.swift
      Onboarding/   OnboardingSheet.swift
      Shared/       RatingPill.swift, BandSymbol.swift, StatusGlyph.swift, ReadinessChip.swift,
                    Format.swift, ToastView.swift
    Resources/      trails.json (the catalog, §4) — generated, never hand-edited after WP1
  Tests/HeavenlyTrackerTests/   TestSupport.swift + one test file per package
```

Dependency rules (enforced by review, not the compiler):

- `Models`, `Rating`, `Style`, `Progression`, `Map/{MapEngine,Picking,CameraPresets,MapSceneBuilder}`
  are pure: no `AppStore`, no SwiftUI views (SwiftUI/AppKit imports allowed only for `Color`/`NSColor`/`NSView`).
- `Map/MapKitEngine` sees only `Map/MapEngine.swift` types and `Trail.ID`/`GeoCoordinate`; it never
  sees `UserTrailState`, `TrailFilter` or `AppStore`.
- `Store/AppStore` depends on Models, Rating, Progression, Persistence, Style. Never on Views or Map.
- `Views/*` depend on `AppStore` (via `@Environment(AppStore.self)`) and on Shared views. `Views/Map`
  is the only view folder that imports `Map/*`.

---

## 3. Data flow

```
 OpenStreetMap ──Overpass──▶ data/raw/heavenly_osm.json ─┐
 AWS terrarium z14 tiles ──▶ data/dem/* ─────────────────┤  tools/build_trails.py (existing, python -I)
                                                         ▼
                        data/trails.json  data/lifts.json  data/boundary.json
                                 │                 │              │
 data/curated_modifiers.json ────┤                 │              │   tools/build_catalog.py  (WP1, stdlib only)
 data/overrides/trail_overrides.json ──┘           │              │   = `make sync-data`
                                 ▼                 ▼              ▼
                 Sources/HeavenlyTracker/Resources/trails.json   (catalog, schema §4, ~0.7 MB)
                                 │  bundled by SwiftPM → HeavenlyTracker_HeavenlyTracker.bundle/Resources/trails.json
 ═══════════════════════════════ runtime ══════════════════════════════════════════════════════════
 CatalogLoader.loadBundled()  ── JSONDecoder ──▶ TrailCatalog
        └─ for each trail: trail.rating = DifficultyRating.breakdown(trail.ratingInput, trail.modifiers)
 UserDataStore.load()  ── userdata.json (+migrations, +backup recovery) ──▶ UserData
        ▼
 AppStore (@Observable, @MainActor)  { catalog, userData, filter, selection, hover, section, toast, … }
   │   mutations: markDone / toggleBucket / logRun / setOverride / … → snapshot-based UndoManager
   │              → revision += 1 → UserDataStore.scheduleSave (500 ms debounce; flush on quit)
   │              → MilestoneRegistry.newlyUnlocked → toast
   ├─▶ Views (Shell, Trails, Inspector, Bucket, Log, Progress) read store; call store mutations
   └─▶ MapScreen: on revision/filter/selection/hover/baseStyle change
            styles = TrailStyleBuilder.styles(for: store)   // [Trail.ID: TrailStyle], pure
            engine.apply(styles:)  engine.setSelection(id)  engine.setCamera(preset)
       MapKitEngine ──delegate──▶ MapScreen: didSelect(id) → store.select(id); didHover → tooltip;
                                   cameraDidChange → persisted CameraState; didFinishLoading(ok:false) → outline fallback
```

Selection flow (UX §2.3): engine click → `Picking.nearest` → `delegate.didSelect(id)` →
`store.select(id, showInspector: true)` → Inspector shows trail → "Done" → `store.markDone(id)` →
revision bump → `MapScreen` recomputes styles → `engine.apply(styles:)` + `engine.animateStatusChange(id, to: .done)`
→ toast with Undo / "Log run…".

---

## 4. The catalog JSON schema the app consumes (final)

File: `Sources/HeavenlyTracker/Resources/trails.json`, produced only by `tools/build_catalog.py`.
Accessed with `Bundle.appResources.url(forResource: "trails", withExtension: "json", subdirectory: "Resources")`
(never `Bundle.module`, see README). Env `HT_CATALOG=/abs/path.json` overrides the bundled file
(dev/testing).

### 4.1 Top level

```json
{
  "schemaVersion": 1,
  "resort": "Heavenly Mountain Resort",
  "generatedAt": "2026-11-01T23:10:00Z",
  "source": {
    "osm": "OpenStreetMap via Overpass API (data/raw/heavenly_osm.json)",
    "license": "ODbL 1.0 (c) OpenStreetMap contributors",
    "osmTimestamp": "2026-11-01T21:22:36Z",
    "elevation": "AWS Terrain Tiles (Mapzen terrarium) z14; see data/dem/dem_meta.json",
    "pipeline": "tools/build_trails.py + tools/build_catalog.py",
    "modifiersVersion": "v1-2026-11-01"
  },
  "ratingEngineVersion": "rating-v1-2026-11-01",
  "bounds": { "minLat": 38.914, "minLon": -119.943, "maxLat": 38.966, "maxLon": -119.881 },
  "trails":     [ Trail … ],        // exactly 126 (named OSM runs)
  "connectors": [ Connector … ],    // 34 unnamed ways: drawn dim, not selectable, not counted
  "lifts":      [ Lift … ],         // 23
  "boundary":   [ [ [lon, lat], … ] ]   // 1 closed outer ring, 338 points
}
```

Coordinates everywhere are **GeoJSON-ordered arrays** `[lon, lat]` or `[lon, lat, ele_m]`
(WGS-84, metres). `GeoCoordinate` has a custom `Codable` for this (BUILD_PLAN WP0). Keys are
camelCase except the verbatim `modifiers` object, which keeps the snake_case keys of
`data/curated_modifiers.json` (provenance; decoded through `CodingKeys` exactly as in RATING_METHOD §3.10).

### 4.2 Trail

```json
{
  "id": "t-gunbarrel",
  "name": "Gunbarrel",
  "pipelineID": "gunbarrel-313466575",
  "osmWayIDs": [313466575],
  "area": "CA",                       // "CA" | "NV"   (pipeline `area`, override-able)
  "areaConfidence": "high",           // "high" | "low" (pipeline)
  "subArea": "gunbarrelFace",         // see 4.6
  "liftName": "World Cup",            // pipeline nearest_lift.name (lift TOP nearest trail top) or null
  "liftAtBottomName": "Gunbarrel Express",
  "osmDifficulty": "expert",          // easy | intermediate | advanced | expert | unknown
  "grooming": "moguls",               // groomed | moguls | backcountry | unknown  (classic→groomed, mogul→moguls, null→unknown)
  "gladed": false,
  "oneway": true,                     // pipeline oneway == "yes"
  "geometry": [ [ [lon, lat, ele], … ], … ],   // one polyline per OSM way = segments[i].coords (≤15 m spacing, TOP→BOTTOM)
  "midpoint": [lon, lat, ele],        // point at half the along-track length of the longest segment
  "top":    [lon, lat, ele],
  "bottom": [lon, lat, ele],
  "stats": {
    "lengthM": 575.9, "verticalDropM": 285.5, "topElevM": 2316.1, "bottomElevM": 2030.6,
    "avgGradePct": 49.58, "maxGradePct": 64.22, "sustainedGradePct": 60.29, "p90GradePct": 61.56,
    "terrainSlopePctP90": 62.72, "aspectDeg": 322.0, "maxSegmentLengthM": 575.9,
    "segmentsRelation": "single"      // single | chained | branches (branches: lengthM is the SUM of parallel branches)
  },
  "profile": [ [0.0, 2316.1, 37.2], [25.0, 2306.8, 33.6], … ],   // [distanceM, elevationM, gradePct]
  "modifiers": {                      // verbatim curated_modifiers.json entry, or {} when uncurated
    "gated": false, "hike_to": false, "chute": false, "cliff_exposure": 0.0, "narrow": false,
    "traverse": false, "moguls_typical": true, "trees": false, "notes": "…", "source": "…"
  },
  "expectedRating": 80                // Python reference formula on the same inputs; Swift must reproduce it exactly
}
```

### 4.3 Connector (unnamed way)

```json
{ "id": "u-313466173", "osmWayID": 313466173, "name": "Unnamed (near Orion)",
  "nearestTrail": "t-orion", "osmDifficulty": "intermediate", "polyline": [ [lon, lat, ele], … ] }
```

### 4.4 Lift

```json
{ "id": "l-313466491", "osmWayID": 313466491, "name": "Aerial Tramway", "kind": "cable_car",
  "area": "CA", "polyline": [ [lon, lat, ele], … ],            // BOTTOM → TOP
  "bottomElevM": 2027.6, "topElevM": 2505.7, "verticalM": 478.2, "lengthM": 1145.9 }
```
`kind`: `chair_lift | gondola | cable_car | magic_carpet | rope_tow`. Station footprints are dropped.

### 4.5 Derivation rules (`tools/build_catalog.py`, stdlib only, `python3 -I`)

| Catalog field | From |
|---|---|
| `id` | `"t-" + slug(name)`; `slug = lower → every run of [^a-z0-9] → "-" → strip "-"`. `The "Y"` → `t-the-y`, `$100 Saddle` → `t-100-saddle`, `Bill's` → `t-bill-s`. Must be unique (126) and match `^t-[a-z0-9-]+$`. Connectors: `"u-" + osm_way_ids[0]`; lifts `"l-" + osm_way_id`. IDs key all user data, so they must stay stable: names, not OSM way ids. |
| `area` | pipeline `area` ("California"→"CA", "Nevada"→"NV"), then `overrides.areaByName`. |
| `subArea` | 1) `overrides.subAreaByName[name]`; 2) `overrides.liftPods` table keyed by `nearest_lift.name` (gunbarrelFace: Gunbarrel Express, World Cup, Aerial Tramway, Patsy's, First Ride, Groove, Pioneer, Big Easy, Tubing Hill · skyCanyonPowderbowl: Sky Express, Canyon Express, Powderbowl Express, Heavenly Gondola · tamarackTop: Tamarack Express · dipperComet: Dipper Express, Comet Express · olympicStagecoach: Olympic Express, Stagecoach Express · boulderGalaxyNorthBowl: Boulder, Galaxy, North Bowl Express, Unnamed magic carpet · mottCanyon: Mott Canyon); 3) `other`. |
| Mott / Killebrew lists (in `overrides.subAreaByName`) | **killebrewCanyon (11)**: Pipeline, Outer Limits, The Fingers, Ramarah's, Bobs Boulevard, Boundry Chutes, Meadows, Pac-Man, Under the Gun, Sweetwater, Rim Trail. **mottCanyon (14)**: Bill's, Ernie's, Hemlock, Hully Gully, Mott Canyon Trail, North 40, On Hold, Pinenuts, Promised Land, Snake Eyes, Southern Comfort, Stateline, The "Y", Widow Maker. Milky Way Bowl → dipperComet, Pinnacles → skyCanyonPowderbowl, Backstroke → tamarackTop. Source: `curated_modifiers.json` gated/hike_to flags + RATING_METHOD §1.4 trip-report cross-check; supersedes UX_SPEC §7.1's geometric lists. |
| `grooming` | classic→groomed, mogul→moguls, backcountry→backcountry, null/list→unknown (a list means mixed; take the first non-null, else unknown). |
| `osmDifficulty` | pipeline value or `unknown`. |
| `geometry` | `segments[*].coords` in pipeline order (already top→bottom, uphill ways reversed). |
| `midpoint` | walk the longest segment (by `stats.length_m`) by haversine distance to half its length, linear interpolation. |
| `profile` | pipeline `profile` with `gradePct[i] = (e[i] − e[i+1]) / (d[i+1] − d[i]) × 100`, last sample repeats the previous grade; single-sample profiles get 0. |
| `stats` | 1:1 rename of pipeline `stats` (values copied unchanged so Python and Swift see identical doubles). |
| `modifiers` | `curated_modifiers[name]` verbatim, else `{}`. |
| `expectedRating` | RATING_METHOD Appendix B Python reference on pipeline `stats` + modifiers (Python `round` = banker's rounding). |
| `bounds` | over all trail, connector and lift coordinates. |

Validation (script exits 1 on failure): 126 trails, unique ids, every polyline ≥ 2 points, all
coordinates inside `bounds`, 90 curated modifiers matched, 11 + 14 canyon trails, the 29 anchors
in `data/calibration_anchors.json` satisfy `|expectedRating − target| ≤ tol`.

### 4.6 Enumerations

`Area`: `CA, NV`. `SubArea`: `gunbarrelFace, skyCanyonPowderbowl, tamarackTop, dipperComet,
olympicStagecoach, boulderGalaxyNorthBowl, mottCanyon, killebrewCanyon, other`. `Band` (derived, never
stored): `green <25, blue <50, black <75, doubleBlack ≥75`.

---

## 5. Rating: how RATING_METHOD.md is wired to the data

- **Source of truth is Swift**: `DifficultyRating.breakdown(_: RatingInput, _: CuratedModifiers) -> RatingBreakdown`
  (`Sources/HeavenlyTracker/Rating/DifficultyRating.swift`), a line-for-line port of RATING_METHOD §3.10.
  It runs once per trail at catalog load (`CatalogLoader`), 126 × microseconds. The pipeline does
  **not** precompute the breakdown; it only ships the inputs plus `expectedRating` as a cross-check.
- **Inputs** (`Trail.ratingInput`):

| RATING_METHOD input | `data/trails.json` | catalog | Swift |
|---|---|---|---|
| `S` sustained_grade_pct (150 m) | `stats.sustained_grade_pct` | `stats.sustainedGradePct` | `RatingInput.sustainedGradePct` |
| `M` max_grade_pct (50 m) | `stats.max_grade_pct` | `stats.maxGradePct` | `.maxGradePct` |
| `V` vertical_drop_m | `stats.vertical_drop_m` | `stats.verticalDropM` | `.verticalDropM` |
| osm_difficulty | `osm_difficulty` (null→unknown) | `osmDifficulty` | `.osmDifficulty: OSMDifficulty` (`.unknown` ≡ nil prior: floor 0, ceiling 100) |
| grooming | `grooming` | `grooming` | `.grooming: Grooming` (`.moguls` ≡ "mogul", `.backcountry`, `.unknown` ≡ nil) |
| gladed | `gladed` | `gladed` | `.gladed` |
| `p90_grade` | `stats.p90_grade_pct` (name differs, diagnostic only) | `stats.p90GradePct` | not used by v1 math |
| curated modifiers | `data/curated_modifiers.json[name]` | `modifiers` (snake_case) | `CuratedModifiers` |

- **Rounding**: Swift uses `s.rounded(.toNearestOrEven)` so it matches Python `round()` exactly;
  `total = clamp(Int(...), 1, 100)`.
- **Breakdown shape** (UX §7.4 reconciled with RATING_METHOD): `RatingBreakdown { total, components,
  raw, afterPrior, afterGate, soft, engineVersion }`, `components` in order with keys
  `base` ("Sustained grade 60%"), `maxPitch`, `fatigue`, `terrain` ("Moguls"/"Trees"/"Ungroomed"),
  `hazards` ("Chute · gated · cliff 0.3"), then only when nonzero `prior` (`afterPrior − raw`),
  `gate` (`afterGate − afterPrior`), `softCap` (`soft − afterGate`). The components sum to `soft`;
  the Inspector renders them as rows and shows `total`.
- **Effective rating** = `userData.trailStates[id].ratingOverride ?? trail.rating.total`; every
  colour, sort, chart and progression computation uses the effective rating (`AppStore.effectiveRating`).
- **Tests** (WP1): (a) feed `data/calibration_anchors.json` inputs → `expected_rating` exactly for
  all 126; (b) bundled catalog: `trail.rating.total == trail.expectedRating` for all 126; (c) the 29
  anchors within `target ± tol`; (d) monotonicity in S and M on a grid.
- Version string `rating-v1-2026-11-01` is stored in the catalog (`ratingEngineVersion`) and in
  every breakdown; the loader logs a warning if they differ.

---

## 6. Conflict resolutions (final)

1. **Trail IDs**: UX spec `t-<slug>` wins over the pipeline's `<slug>-<wayids>`; the pipeline id is
   kept as `pipelineID`. Milestone ids `t-gunbarrel`, `t-the-face` stay valid.
2. **Bands and colours**: UX_SPEC §8.1's 9-stop ramp and 4 bands at 25/50/75 (green/blue/black/
   double-black glyphs) are the single visual system. RATING_METHOD §6's six display bands and
   colours are **not** used (the number is the method's job; the look is the spec's).
3. **Rating breakdown keys**: RATING_METHOD's terms (§5 above) replace UX §7.4's guessed keys
   (`avgGrade`, `gradeVariance`, …) and its "bands spill ≤ 8 points" rule; the prior/gate/soft cap
   of the method apply instead.
4. **Conditions**: UX §6.3 single-pick `Conditions` enum with its 8 multipliers is V1 (one segmented
   control in the Log Run sheet). RATING_METHOD §7's multi-group product model is deferred.
5. **Skill model**: UX §7.5 `DefaultProgressionEngine` (weighted 80th percentile, confidence 1–5,
   readiness kinds, suggestion reasons) is V1. RATING_METHOD §8's cumulative-weight ceiling is deferred;
   its gating rule is adopted as a readiness tweak: gated trails are never "ready" below skill 58,
   hike-to never below 65 (reason text "behind a gate — build to 58 first").
6. **Area (CA/NV)**: the pipeline's lift-pod vote (50 CA / 76 NV, with `area_confidence`) wins over
   the spec's oblique-line heuristic (43/83); overrides file for hand fixes.
7. **Sub-areas / Mott vs Killebrew**: curated lists (§4.5) from the rating agent's trip-report
   cross-check supersede the spec's geometric split.
8. **Unnamed ways**: shipped as `connectors` (34), drawn dim, unselectable, uncounted — per UX
   §7.1 — even though one ("Unnamed (near Double Down) #1") is a real run. Revisit later.
9. **Camera presets**: UX §2.5 numbers (14 km/55°, 6.5 km/60°) are impossible in MapKit; replaced
   by §8.6.
10. **Hit threshold**: 14 pt (spec said ≥ 8).
11. **Legend placement**: top-left (spec: bottom-left) to keep the Apple attribution visible.
12. **Module layout**: folders in one executable target (task + build agent) instead of the spec's
    `HeavenlyCore` library.
13. **Resources**: `Bundle.appResources` + `subdirectory: "Resources"` everywhere (build agent's
    finding); `Makefile sync-data` now runs `build_catalog.py` instead of copying `data/trails.json`.
14. **`p90_grade` vs `p90_grade_pct`**: catalog uses `p90GradePct`; not used by the formula.
15. **127 vs 126 trails**: 126.
16. **Badges**: the MapKit engine *does* declare `.badges` and `.labels` (selected-only label) using
    `MKAnnotationView`, so badges track the terrain during camera animation; the overlay-drawn path
    from the spec is the fallback if annotation views misbehave on realistic terrain (WP3 decides by
    screenshot and records which path shipped).
17. **Swift language mode**: stays `.v5`; `MapKitEngine` and `AppStore` are `@MainActor` so a later
    flip to v6 is cheap.
18. **UX §7.1 `catalog.connectors: [[GeoCoordinate]]`** becomes `[Connector]` (id + nearest trail).

---

## 7. The abstract `MapEngine` interface (normative Swift)

`Sources/HeavenlyTracker/Map/MapEngine.swift` — written verbatim by WP0, never edited afterwards.

```swift
import Foundation
import AppKit

/// Static scene: everything that only changes when the catalog is reloaded.
struct MapScene {
    var trails: [TrailGeometry]          // 126 named trails
    var connectors: [[GeoCoordinate]]    // unnamed ways, dim, not selectable
    var lifts: [LiftGeometry]
    var boundary: [[GeoCoordinate]]
    var bounds: GeoBounds
}
struct TrailGeometry: Identifiable {
    let id: Trail.ID
    let name: String
    let polylines: [[GeoCoordinate]]     // one per OSM way
    let midpoint: GeoCoordinate
    let bounds: GeoBounds
}
struct LiftGeometry: Identifiable {
    let id: Lift.ID
    let name: String
    let kind: LiftKind
    let polyline: [GeoCoordinate]        // bottom → top
}

/// Per-trail dynamic style, computed by TrailStyleBuilder (UX §2.2); the engine only draws it.
struct TrailStyle: Equatable {
    enum Badge: Equatable { case none, done, bucket }
    enum Emphasis: Equatable { case normal, dimmed, hovered, selected }
    var color: RGBA            // ramp(rating), already desaturated for done
    var casing: RGBA
    var opacity: Double
    var baseWidth: Double      // pt at the 11 km overview; engine scales ×clamp(11000/distance, 1, 2)
    var dash: [Double]?        // nil = solid
    var badge: Badge
    var emphasis: Emphasis
    var label: String?         // shown only when selected
}

enum CameraPreset: Equatable { case overview, california, nevada, mottKillebrew, fit(Trail.ID) }
struct CameraState: Codable, Equatable {
    var center: GeoCoordinate
    var distanceM: Double
    var headingDeg: Double     // direction the camera looks, 0 = north
    var pitchDeg: Double       // ACTUAL pitch after the engine's clamp
}
enum MapBaseStyle: String, CaseIterable, Codable { case satellite, terrain, outline }

struct MapEngineCapabilities: OptionSet {
    let rawValue: Int
    static let terrain3D    = Self(rawValue: 1 << 0)
    static let pitch        = Self(rawValue: 1 << 1)
    static let hover        = Self(rawValue: 1 << 2)
    static let badges       = Self(rawValue: 1 << 3)   // engine draws midpoint glyphs itself
    static let animateStyle = Self(rawValue: 1 << 4)
    static let labels       = Self(rawValue: 1 << 5)   // engine draws the selected trail's label
    static let offline      = Self(rawValue: 1 << 6)
}

@MainActor
protocol MapEngineDelegate: AnyObject {
    func mapEngine(_ engine: any MapEngine, didSelect trailID: Trail.ID?)              // nil = clicked empty terrain
    func mapEngine(_ engine: any MapEngine, didHover trailID: Trail.ID?, at point: CGPoint?)  // point in the engine view's coords (top-left origin)
    func mapEngine(_ engine: any MapEngine, cameraDidChange camera: CameraState)
    func mapEngine(_ engine: any MapEngine, didFinishLoading ok: Bool, error: Error?)
}

@MainActor
protocol MapEngine: AnyObject {
    static var displayName: String { get }
    var capabilities: MapEngineCapabilities { get }
    var supportedBaseStyles: [MapBaseStyle] { get }
    var delegate: (any MapEngineDelegate)? { get set }

    /// The NSView to host; called once by MapHostView.
    func makeView() -> NSView

    // Inputs
    func load(scene: MapScene)                                   // (re)build all geometry
    func apply(styles: [Trail.ID: TrailStyle])                   // full map every time; engine diffs against last applied
    func setSelection(_ id: Trail.ID?)                           // visual only; truth lives in AppStore
    func setBaseStyle(_ style: MapBaseStyle)
    func setCamera(_ preset: CameraPreset, animated: Bool)
    func setCamera(_ state: CameraState, animated: Bool)
    func animateStatusChange(_ id: Trail.ID, to badge: TrailStyle.Badge)   // no-op without .animateStyle

    // Queries for SwiftUI overlays (synchronous)
    func currentCamera() -> CameraState
    func project(_ c: GeoCoordinate) -> CGPoint?                 // nil only when off-screen (MapKit cannot see terrain occlusion)
    func hitTest(_ point: CGPoint) -> Trail.ID?                  // same math the click path uses; for tests and dev hooks
}
```

Contract notes (binding on `MapKitEngine` and any future engine):

- `apply(styles:)` is called on every status/filter/selection/hover change; it must diff and touch
  only changed trails (≤ 126 entries, < 2 ms).
- Hit-testing is the engine's job; threshold 14 pt; one hit per `Trail.ID` (all ways of a run).
- If the base map fails to load, the engine switches itself to `.outline` and reports
  `didFinishLoading(ok: false, error:)`; polylines must remain visible. The app never shows a blank map.
- `cameraDidChange` is emitted after every user gesture end and after every programmatic move with
  the camera MapKit actually kept (pitch clamp read back).
- The engine never draws UI chrome; legend, chips, tooltip and toast are SwiftUI overlays.

---

## 8. `MapKitEngine` design (WP3)

### 8.1 View setup
`MKMapView` with `preferredConfiguration` per §8.4, `pointOfInterestFilter = .excludingAll`,
`showsCompass = true`, `showsPitchControl = false`, `showsZoomControls = false`, all interaction
enabled, `cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_200,
maxCenterCoordinateDistance: 30_000)`, `cameraBoundary = MKMapView.CameraBoundary(coordinateRegion:
bounds padded 4 km)`. `isFlipped == true` on macOS: points from `convert(_:toPointTo:)` are already
top-left-origin; keep the spike's guard anyway.

### 8.2 Overlay model
```
TrailOverlay: MKPolyline   { trailID, wayIndex, role: .casing | .stroke | .glow }
LiftOverlay:  MKPolyline   { liftID, kind }
ConnectorOverlay, BoundaryOverlay: MKPolyline
```
`load(scene:)` adds, in order: boundary, connectors, lifts, every trail's casing, every trail's stroke
(z-order = add order within one level). A `[Trail.ID: [TrailOverlay]]` index and a renderer cache
`[ObjectIdentifier: MKPolylineRenderer]` (filled in `mapView(_:rendererFor:)`) make `apply(styles:)`
a renderer mutation: `strokeColor`, `lineWidth`, `alpha`, `lineDashPattern`, then `setNeedsDisplay()`.
Selection (`setSelection`) is the only remove/re-add: the selected trail's casing + stroke + a `.glow`
overlay (white 60 %, width × 1.8 + 8 pt) are re-added with `addOverlays(_:level: .aboveLabels)`
so they sit on top. Width scaling: on `regionDidChangeAnimated`, `scale = clamp(11_000 /
camera.centerCoordinateDistance, 1, 2)`; every renderer's `lineWidth = style.baseWidth × scale`
(casing +2 pt, glow as above).

### 8.3 Picking and hover
`Picking.nearest(to:in:bounds:threshold:)` is the spike's `pickTrail` made pure (`Map/Picking.swift`,
unit-tested). Projected vertices are cached per camera (`ProjectionCache { cameraKey, polylines:
[ProjectedPolyline] }`), invalidated when `mapView.camera` differs from the cached key; ≈ 6,559
points, ~1 ms to rebuild. Click: `NSClickGestureRecognizer` → `hitTest` → `delegate.didSelect`.
Hover: `NSTrackingArea(.mouseMoved, .activeInKeyWindow, .inVisibleRect)` → throttled to 30 Hz →
`hitTest` → `delegate.didHover` only on change; the overlay shows the tooltip after 150 ms. A click
that hits nothing emits `didSelect(nil)`.

### 8.4 Base styles
| `MapBaseStyle` | Configuration |
|---|---|
| `.satellite` (default) | `MKImageryMapConfiguration(elevationStyle: .realistic)` **if** WP3's first screenshot (run the spike with `SPIKE_STYLE=imagery`) shows terrain relief and pitch; otherwise `MKHybridMapConfiguration(elevationStyle: .realistic)` with POIs excluded (verified by the spike). Record the outcome in a code comment. |
| `.terrain` | `MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)` |
| `.outline` | `MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)`; pitch is forced to 0 by MapKit — expected. Also the automatic fallback on `mapViewDidFailLoadingMap`. |

`capabilities = [.terrain3D, .pitch, .hover, .badges, .animateStyle, .labels]` (no `.offline`).

### 8.5 Badges and labels
`MKPointAnnotation` at each trail midpoint with a custom `MKAnnotationView` (18 pt disc:
`checkmark` on `#34C759` for done, `star.fill` yellow on dark for bucket; hidden for `.none`),
`displayPriority = .required`, `collisionMode = .circle`. The selected trail gets a second annotation
with a label view (`name · ◆ 72`). If annotation views float or lag on realistic terrain, WP3 drops
`.badges`/`.labels` from `capabilities` and `MapOverlays.swift` draws them with `project(midpoint)`
on `cameraDidChange`, accepting lag during animations.

### 8.6 Camera presets (`CameraPresets.state(for:scene:viewSize:)`, pure; tune by screenshot)

| Preset | Center (lat, lon) | Distance | Heading | Pitch | Note |
|---|---|---|---|---|---|
| `.overview` | 38.938, −119.913 | 11,000 m × max(1, 900 / viewWidthPt) | 180° | 35° | from over the lake looking south; 35° is MapKit's cap here |
| `.california` | 38.927, −119.923 | 2,900 m | 165° | 60° | Gunbarrel/Face/Sky/Canyon |
| `.nevada` | 38.943, −119.895 | 2,900 m | 210° | 60° | Olympic/Stagecoach/Dipper/Comet |
| `.mottKillebrew` | 38.929, −119.891 | 2,600 m | 165° | 60° | looking SSE at the north-facing chute wall |
| `.fit(id)` | trail bounds center | max(1,200, diagonal × 2.5) | current | 60° if ≤ 3,000 m else 35° | pads 30 % |

The last `CameraState` is saved in `UserDefaults["map.lastCamera"]` on every `cameraDidChange` and
restored at launch; `Cmd+0` / `Cmd+Opt+1/2/3` / chips request presets through `AppStore.cameraRequest`.

### 8.7 Loading, failure, attribution, memory
`mapViewDidFinishLoadingMap` → `didFinishLoading(ok: true)`; `mapViewDidFailLoadingMap` →
`setBaseStyle(.outline)` + `didFinishLoading(ok: false, error)`; MapScreen shows a dismissible
banner. The Apple logo/legal link (bottom-left of the `MKMapView`) is never covered; the legend is
top-left, chips bottom-right, "Trails © OpenStreetMap contributors (ODbL)" in 10 pt above the chips.
Budget: ≤ 1.0 GB footprint at the closest allowed camera, idle CPU ≈ 0 (MapKit renders on demand).

### 8.8 Cross-off animation
`animateStatusChange(id, to: .done)`: casing → white, width × 2.2 for 250 ms (renderer mutation +
`setNeedsDisplay`), then `apply` the final style; the badge annotation view scales 0 → 1.3 → 1.0 with
`NSAnimationContext` (spring-like, 0.45 s). Haptic and toast are the store's/overlay's job.

---

## 9. User data and persistence (WP2)

Types are UX_SPEC §7.2 verbatim (`TrailStatus`, `UserTrailState`, `Conditions`, `RunLogEntry`,
`SkiDayMeta`, `SkillPoint`, `UserProfile`, `UserData`), defined in `Models/UserData.swift` by WP0.

- Location: `~/Library/Application Support/HeavenlyTracker/userdata.json` (+ `userdata.backup.json`,
  `userdata.corrupt-<ts>.json`, `userdata.pre-import-<ts>.json`). Env **`HT_USERDATA_DIR`** redirects
  the whole directory (tests, screenshots, dev hooks never touch real data).
- Encoding: `JSONEncoder` with `.iso8601` dates, `[.prettyPrinted, .sortedKeys]`; atomic write to
  `userdata.json.tmp` + `replaceItemAt`; previous file becomes the backup on each successful save.
- Save policy: 500 ms debounce after any mutation (`AppStore.revision` bump); synchronous `flush()`
  on `NSApplication.willTerminateNotification`, on export, and on window close.
- Load: missing → `UserData.fresh()`; decode failure → backup → else rename to `.corrupt-<ts>` and
  start fresh with an alert; `schemaVersion` newer than the app → refuse with an alert.
- `Migrations.run(json:from:)` dictionary transforms, `currentVersion = 1`.
- Pruning: `UserTrailState.isEmpty` entries dropped on save; `trailStates`/`runLog` ids not in the
  catalog are kept (shown as "Unknown trail" in the Log).
- Undo: every mutation snapshots `userData` and registers `restore(snapshot)` with the window's
  `UndoManager` (handed to the store by `RootView` from `@Environment(\.undoManager)`).
- `UserDefaults` keys (per-machine UI prefs, not exported): `ui.section`, `ui.inspectorShown`,
  `ui.legendShown`, `map.baseStyle`, `map.lastCamera` (JSON `CameraState`), `trails.columns`,
  `onboarding.done`, `units`.
- Export/Import: `Cmd+Shift+E` writes the document + `exportedAt`; `Cmd+Shift+I` decodes with
  migrations and offers **Replace** (backs up first). Merge is P1 (UX §7.8) — only if WP2 finishes
  P0 early.

---

## 10. Progression and milestones (WP5)

`DefaultProgressionEngine` implements UX §7.5 exactly (per-run `e = effectiveRating × multiplier`,
`m = e + 4·(confidence − 3)`, weighted 80th percentile over trailing 60 days with weight
`0.5^(ageDays/30)`, `< 3 runs → max(m) − 5`, none → `selfAssessedStart`, smoothing
`max(raw, 0.9·prev)`, interval `±(10 − min(basisRuns, 7))`, readiness cuts −8 / 7 / 15), plus the
gated/hike-to rule from §6.5. `MilestoneRegistry` implements UX §7.6 (14 badges + counts). Skill
history is recomputed from the log on load and after every log mutation and cached in
`profile.skillHistory`. Both engines are pure and unit-tested with synthetic logs.

---

## 11. Dev hooks and headless verification

`App/DevHooks.swift` (WP0) reads these env vars at launch and applies them to `AppStore` 0.5 s after
the window appears, so every package can screenshot real states without a human:

| Env | Effect |
|---|---|
| `HT_SCREENSHOT=/abs.png`, `HT_SCREENSHOT_DELAY=10` | existing `SelfCapture`: capture window, write `<png>.txt`, exit 0 |
| `HT_USERDATA_DIR=/abs/dir` | persistence directory (always set it in scripted runs) |
| `HT_CATALOG=/abs/trails.json` | load this catalog instead of the bundled one |
| `HT_SKIP_ONBOARDING=1` | implied when `HT_SCREENSHOT` is set |
| `HT_SECTION=map\|trails\|bucket\|progress\|log` | initial sidebar section |
| `HT_SELECT=t-gunbarrel` | select trail (shows inspector) |
| `HT_CAMERA=overview\|california\|nevada\|mottKillebrew\|fit` | camera preset after selection |
| `HT_BASE_STYLE=satellite\|terrain\|outline` | base style |
| `HT_MARK_DONE=t-gunbarrel,t-maggie-s` | mark done at +1 s (exercises animation + toast + persistence) |
| `HT_BUCKET=t-bill-s` | add to bucket |

Run the bare executable (`.build/<config>/HeavenlyTracker`) for ad-hoc shots (no LaunchServices
quirk), or the assembled app with `-ApplePersistenceIgnoreState YES` (see README). Always use
`run_in_background`/`timeout`, and look at the PNG with the Read tool before claiming anything rendered.

---

## 12. Open risks

1. `MKImageryMapConfiguration` + realistic elevation on macOS is unverified (only hybrid was run).
   Fallback is defined (§8.4); cost is street labels on the mountain.
2. `MKAnnotationView` badges on realistic terrain are unverified; fallback defined (§8.5).
3. Gray-grid sky at the close presets: the spike's 2.5 km / 60° shot showed a strip at the top with
   heading 160; WP3 must re-check at 2.9 km / 60° and lower pitch to 55° if needed.
4. Network dependency: offline users get `.outline` with trails only. Acceptable for V1.
5. Memory ~1 GB at the closest camera on 8 GB Macs. Mitigated by the 1,200 m floor; not eliminated.
6. Catalog `area`/`subArea` are heuristics with an override file; nobody has checked them against
   the official trail map. Not a blocker; data-only fix.
7. The pipeline's DEM is 7.4 m resampled 10 m 3DEP (±5 m RMSE); The Face reads 50 % sustained and is
   rated 67 against a human anchor of 72 ± 6. Within tolerance; documented in RATING_METHOD.
8. Swift ↔ Python rating equality depends on identical doubles and banker's rounding; the WP1 test
   catches drift immediately.
9. Parallel agents share one working tree; BUILD_PLAN §0.3 prescribes per-package copies to avoid
   half-written files breaking each other's builds.
10. `swift test` is a silent no-op under CLT (builds, runs nothing, exit 0). Any agent that reports
    "tests pass" from `swift test` has verified nothing; `tools/run_tests.sh` must print
    `✔ Test run with N tests … passed`. The build agent's earlier "2 tests pass" report was wrong.
