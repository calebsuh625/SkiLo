# MapKit 3D terrain spike (macOS)

Feasibility spike for the SkiLo 3D trail map using Apple MapKit. Two variants share
`Shared.swift` (OSM loading, screen-space picking, screenshot/click/drape test helpers):

- `main.swift`  -> `spike`    SwiftUI `Map` + `MapPolyline`, `.mapStyle(.hybrid(elevation: .realistic))`,
                              `MapReader` + `onTapGesture` picking.
- `MKSpike.swift` -> `spike_mk` `MKMapView` in an `NSViewRepresentable`, `MKHybridMapConfiguration(elevationStyle: .realistic)`,
                              `MKPolyline` overlays, `NSClickGestureRecognizer` picking, render-complete timing, pitch-clamp probe.

Both are bare executables (no .app bundle, no xcodebuild). They read
`/Users/calebsuh/Projects/SkiLo/data/raw/heavenly_osm.json` (hardcoded), draw all downhill pistes
colored by `piste:difficulty` and lifts, then after `SPIKE_DELAY` seconds screenshot themselves into `out/`,
run a pick-function test and a synthetic-click test, screenshot again, analyze the screenshot, log, and exit.

```sh
./build.sh                       # swiftc via Command Line Tools (DEVELOPER_DIR=/Library/Developer/CommandLineTools)
./run.sh realistic 12 hybrid     # SwiftUI variant: elevation realistic|flat, delay seconds, style hybrid|imagery|standard
SPIKE_DELAY=10 ./spike_mk        # MKMapView variant (writes out/mk/)
SPIKE_STAY=1 ./spike             # keep the window open for manual interaction instead of exiting
```

Env knobs: `SPIKE_ELEVATION`, `SPIKE_STYLE`, `SPIKE_DELAY`, `SPIKE_DISTANCE`, `SPIKE_PITCH`, `SPIKE_HEADING`,
`SPIKE_OUT`, `SPIKE_TAG`, `SPIKE_STAY`. Logs and screenshots land in `out/` (git-ignored by `.gitignore` here).

Data: OpenStreetMap via Overpass, ODbL. Map tiles/terrain: Apple Maps (network required).
