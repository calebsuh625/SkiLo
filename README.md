## How to run (no tech skills needed)
Double-click `SkiLo.app` in your Applications folder (Home > Applications). If macOS says it is blocked or from an unidentified developer, right-click the app and choose Open, then click Open again. You only have to do this once.

# SkiLo

A native macOS ski progression tracker for Lake Tahoe: Heavenly, Kirkwood and Mt. Rose.
Fine-grained 1–100 trail difficulty ratings, a 3D trail map, a bucket list you can cross off,
A-to-B directions on the mountain, a day planner tuned to the forecast, and 3D fly-throughs.

Trail geometry is derived from OpenStreetMap (© OpenStreetMap contributors, ODbL) — see
`data/raw/PROVENANCE.json`.

## Usage

```sh
tools/build_app.sh run        # build and open the app
tools/run_tests.sh            # all tests; look for "Test run with N tests ... passed"
tools/run_tests.sh --filter Rating
```

**Bare `swift test` is a silent no-op under the Command Line Tools** (it builds the bundle and
runs nothing, exit 0). `tools/run_tests.sh` builds a small dlopen host that calls swift-testing's
entry point. Fallback only: `env -u DEVELOPER_DIR swift test` with a full Xcode toolchain.

First launch asks you to create an account (username + password, stored only on this Mac;
"Remember me" keeps you signed in). A new account then shows the onboarding sheet (self-rated
skill 1-100, optional backfill). Sections: Map (3D MapKit terrain, 126 colour-coded trails, click
to select), Trails (sortable table), Bucket List, Progress, Log. Every completed run updates your
Elo (`Progression/Elo.swift`).

Data lives in `~/Library/Application Support/SkiLo/`: `accounts.json` (usernames + salted
PBKDF2 password hashes) and `accounts/<id>/userdata.json` per account (atomic writes, undo in memory).

## Directions, Today and fly-throughs

- **Directions (⌘G, or "Directions Here" on any trail):** pick a start and destination (lodges,
  tops/bottoms of lifts, trails, or click the map) and a limit: *Comfortable* (≤ your Elo),
  *Push it a bit* (≤ Elo + 15) or *Anything*. Routes ride lifts up, ski trails down and use cat
  tracks between them; times scale with your Elo. If nothing fits the limit you get the gentlest
  route that does, with the harder trails named. Mark lifts closed for the day and routes avoid them.
  Code: `Shared/Routing/` (graph + Dijkstra, tested in `RoutingTests`).
- **Today:** a 5-day mountain forecast (Open-Meteo, no account; cached an hour in
  `Application Support/SkiLo/cache`), a read of the snow (powder, fresh, storm, firm, spring,
  packed; override it if you know better) and **Today's Pick**: trails that suit the conditions
  and your level. Add picks, bucket-list trails or any trail to the **Day Plan**: SkiLo orders them,
  routes every leg from your lodge, times it against lift closing, and can show it on the map,
  fly through it, or **Send to Phone** (AirDrop/Messages image, text, or saved PNG).
- **Fly Through (⌥⌘P):** a chase camera down any trail, or along a whole route or planned day.

## Resorts

The sidebar's resort menu (⌃⌘1–3) switches between Heavenly, Kirkwood and Mt. Rose. Your Elo,
run log and bucket list span all of them; the map, trail list, picks, routes and progress show the
resort you're on. All three use one rating scale: the same terrain formula plus researched hazard
modifiers (gates, chutes, cliffs, hikes, trees, moguls) in `data/curated_modifiers.json` (Heavenly)
and `data/<resort>/curated_modifiers.json`, so an 80 means the same thing everywhere. Heavenly also
has 29 calibration anchors. Mt. Rose leaves out Sky Tavern, the separate hill next door.

## iPhone app

`SkiLoiOS.xcodeproj` builds the iPhone app (iOS 18+). It compiles `Sources/SkiLo/Shared/` (models,
ratings, Elo, accounts, store, shared views) plus the phone-only screens in `iOS/App/`, so the Mac
and iPhone apps share one codebase. Mac-only code lives in `Sources/SkiLo/Mac/`.

- **Simulator:** open `SkiLoiOS.xcodeproj` in Xcode, pick an iPhone simulator, press Run.
- **Your iPhone:** in Xcode select the SkiLo target → Signing & Capabilities → choose your Apple ID
  team, plug in the phone, press Run. With a free Apple ID the app expires after 7 days.
- Tabs: Map (3D satellite, tap a trail), Trails (swipe right = done / ran again, left = bucket),
  Bucket, Progress, Me (account, run log). Accounts and data stay on each device; they do not sync.

## Data provenance and regeneration

- `data/` holds the source inputs (OSM extract, DEM tiles, curated modifiers, calibration anchors,
  overrides in `data/overrides/trail_overrides.json`).
- `tools/build_catalog.py` merges them and computes the 1-100 rating for each trail (method:
  `docs/RATING_METHOD.md`; it asserts the 29 calibration anchors are within tolerance). It writes
  `Sources/SkiLo/Resources/trails.json` (126 trails, 34 connectors, 23 lifts).
  Regenerate with `tools/build_app.sh sync-data`; output is idempotent apart from `generatedAt`.
- The Swift rating code (`Rating/DifficultyRating.swift`) is tested to match the Python output.
- Other resorts: `tools/build_trails.py --resort=kirkwood` (or `mtrose`) reads
  `data/<resort>/raw/osm.json` (Overpass export) and writes `data/<resort>/`; then
  `tools/build_resort_catalog.py <resort>` writes `Sources/SkiLo/Resources/trails-<resort>.json`
  (ids prefixed `t-kw-` / `t-mr-` so they never collide). Lodges, camera views and forecast
  points live in `Shared/Models/Resort.swift`.

## Attribution

- Trail, lift and boundary geometry: (c) OpenStreetMap contributors, ODbL
  (https://www.openstreetmap.org/copyright). The map shows this credit.
- Base map, satellite imagery and 3D terrain: Apple Maps / MapKit (Apple logo and Legal link are
  kept visible).
- Elevation: AWS Open Data Terrain Tiles (Terrain Tiles on AWS; sources include USGS 3DEP/NED,
  SRTM and others) used to derive vertical, grade and elevation profiles.

## Dev hooks (headless verification)

Set before launching the binary (`-ApplePersistenceIgnoreState YES` for the bundled app). Always
set `HT_USERDATA_DIR` in scripted runs so real data is not touched.

| Env | Effect |
|---|---|
| `HT_SCREENSHOT=/abs.png`, `HT_SCREENSHOT_DELAY=s` | capture own window, write `<png>.txt`, exit (also skips onboarding) |
| `HT_SHOW_ONBOARDING=1` | show onboarding even when `HT_SCREENSHOT` is set |
| `HT_SKIP_ONBOARDING=1` | skip onboarding |
| `HT_USERDATA_DIR=/abs/dir` | persistence directory |
| `HT_CATALOG=/abs/trails.json` | alternate catalog |
| `HT_SECTION=map\|trails\|bucket\|progress\|log` | initial section |
| `HT_SELECT=<trail id>` | select a trail |
| `HT_CAMERA=overview\|california\|nevada\|mottKillebrew\|fit` | camera preset |
| `HT_BASE_STYLE=satellite\|terrain\|outline` | base map style |
| `HT_MARK_DONE=id,id` / `HT_BUCKET=id,id` | mark done / add to bucket |
| `HT_CLICK=<trail id>` (`HT_CLICK_DELAY`) | synthetic click on the map, logs PASS/FAIL |
| `HT_RESORT=heavenly\|kirkwood\|mtrose` | resort to show |
| `HT_DIRECTIONS="<lodge or lift>><trail id>"`, `HT_DIFFICULTY`, `HT_FIT_ROUTE=1` | open directions |
| `HT_FLY=<trail id>\|route` (`HT_FLY_DELAY`) | start a fly-through |
| `HT_PLAN=top5\|id,id`, `HT_PLAN_SHOW=1`, `HT_FORECAST_FILE=/abs.json` | build a day plan / use a saved forecast |
| `HT_PROJ_DEBUG=1`, `HT_SAT_CONFIG=imagery\|hybrid`, `HT_MAP_LOG=1` | map engine debugging |

See `docs/ACCEPTANCE.md` for the verified V1 walk-through.

## Building without Xcode license

Xcode is installed on this machine but its license has not been accepted, so `xcodebuild` —
and every `/usr/bin/*` xcode-select shim, **including `/usr/bin/make`** — fails with
"You have not agreed to the Xcode license agreements". The project therefore builds entirely
with the **Command Line Tools** toolchain (Swift 6.3, `/Library/Developer/CommandLineTools`)
via SwiftPM plus a Makefile that assembles the `.app` bundle by hand.

Use the wrapper, which pins `DEVELOPER_DIR` and calls CLT's own `make`:

```sh
tools/build_app.sh            # swift build -c release -> build/SkiLo.app (ad-hoc signed)
tools/build_app.sh debug      # same, debug configuration
tools/build_app.sh run        # build + open build/SkiLo.app
tools/build_app.sh test       # runs tools/run_tests.sh (swift-testing)
tools/build_app.sh verify     # launch the .app headless, self-screenshot to build/verify.png,
                              #   print the resource-bundle status, exit
tools/build_app.sh sync-data  # regenerate Sources/SkiLo/Resources/trails.json (tools/build_catalog.py)
tools/build_app.sh clean
```

Equivalent without the wrapper — the export is mandatory, otherwise `make`/`swift` hit the
license check:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
make            # or any target above
swift build -c release
tools/run_tests.sh   # NOT bare `swift test`
```

### How the .app is assembled (`make app`)

1. `swift build -c $(CONFIG)` (release by default).
2. Copy `.build/<arch>-apple-macosx/<config>/SkiLo` → `Contents/MacOS/`.
3. Copy the SwiftPM resource bundle `SkiLo_SkiLo.bundle` → `Contents/Resources/`.
4. Copy `tools/Info.plist` → `Contents/Info.plist` (bundle id `com.calebsuh.SkiLo`,
   `LSMinimumSystemVersion 15.0`, `NSHighResolutionCapable`, `NSPrincipalClass NSApplication`),
   write `PkgInfo`, copy `assets/AppIcon.icns` if it exists (else the `CFBundleIconFile` key is
   dropped).
5. `codesign --force --deep --sign - build/SkiLo.app` and verify.

### Resources: use `Bundle.appResources`, not `Bundle.module`

`Package.swift` declares `resources: [.copy("Resources")]`, so everything under
`Sources/SkiLo/Resources/` is bundled and addressed with a `subdirectory: "Resources"`:

```swift
Bundle.appResources.url(forResource: "trails", withExtension: "json", subdirectory: "Resources")
```

Why not `Bundle.module`? Pure SwiftPM generates an accessor that only checks
`Bundle.main.bundleURL/<name>.bundle` — for a `.app` that is the **app root**, which `codesign`
rejects ("unsealed contents present in the bundle root") — and then a hard-coded absolute
`.build/...` path. It never looks in `Contents/Resources`. Tested empirically with the `.build`
copy hidden: bundle in `Contents/Resources` → fatalError; in `Contents/MacOS` → fatalError;
at the app root → works but cannot be signed. `Bundle.appResources`
(`Sources/SkiLo/AppResources.swift`) checks `Contents/Resources` first and falls back
to `Bundle.module`, so `swift run` and `swift test` still work from `.build/`.

### Tests

CLT ships `Testing.framework` (swift-testing) but **not** `XCTest.framework`. Write tests with
`import Testing` / `@Test` / `#expect`; `import XCTest` will not compile under CLT.

CLT also lays out swift-testing differently from Xcode (`<CLT>/Library/Developer/Frameworks`
and `<CLT>/Library/Developer/usr/lib/lib_TestingInterop.dylib`), so a stock `swift test` fails
with `no such module 'Testing'` and then `Library not loaded: @rpath/lib_TestingInterop.dylib`.
`Package.swift` detects `DEVELOPER_DIR` pointing at CLT and adds the needed `-F` / `-rpath`
flags to the test target. If you ever need them by hand:

```sh
CLT=/Library/Developer/CommandLineTools
swift test -Xswiftc -F$CLT/Library/Developer/Frameworks \
  -Xlinker -F$CLT/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib
```

### Other gotchas

- **Language mode:** tools-version 6.0 with `.swiftLanguageMode(.v5)` on both targets, so
  SwiftUI/MapKit/SceneKit delegate code produces concurrency *warnings*, not Swift 6 *errors*.
  Flip to `.v6` per-target when ready.
- **Bare executable windows:** running `.build/release/SkiLo` directly (no
  `Info.plist`) still opens a window because `AppDelegate` forces
  `NSApp.setActivationPolicy(.regular)`.
- **Headless screenshots:** set `HT_SCREENSHOT=/abs/path.png` (optional
  `HT_SCREENSHOT_DELAY=<seconds>`, default 3) when launching the binary; it captures its own
  window with `screencapture -l <windowNumber>`, writes `<path>.txt` with the resource-bundle
  status, and exits. The terminal may need Screen Recording permission the first time.
- **Direct launch of `Contents/MacOS/SkiLo` shows no window** after the app has been
  launched once through LaunchServices (`make run` / Finder): `NSApp.windows` stays empty
  indefinitely. Deleting the visible saved state (`$TMPDIR/com.calebsuh.SkiLo.savedState`,
  the Preferences plist) does not clear it, but launching with `-ApplePersistenceIgnoreState YES`
  always works, and `open` always works. `make verify` therefore passes that flag; do the same
  for any ad-hoc direct launch of the bundled binary. The bare `.build/<config>/SkiLo`
  executable is unaffected.
- `/usr/bin/timeout` exists on this macOS and is used by `make verify`.

### Opening in Xcode later

Once the Xcode license is accepted (`sudo xcodebuild -license accept`, needs an admin password),
`open Package.swift` lets Xcode open the SwiftPM package directly with full IDE support; the
Makefile keeps working unchanged. (Xcode's own build system generates a different
`Bundle.module` accessor that *does* check `Contents/Resources`; `Bundle.appResources` works
under both.)
