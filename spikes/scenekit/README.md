# SceneKit 3D terrain spike (Heavenly)

Feasibility spike: fully custom 3D terrain map in SceneKit (SCNView inside SwiftUI via NSViewRepresentable),
real DEM, OSM pistes draped on the surface, orbit camera, click picking.

## Build / run (Command Line Tools only, no xcodebuild)
    ./build.sh                      # swiftc -O, target arm64-apple-macosx15.0 -> ./SceneKitSpike
    ./run.sh                        # interactive window (drag = orbit, scroll = zoom)
    ./run.sh /abs/path/shot.png     # auto: pick test at 2.5 s, screenshot + run_stats.json at 6.5 s, exit
Env: DEM_STRIDE (default 2 -> 825x817 grid), SPIKE_TEXTURE (hillshade_tex.png | satellite_z15.jpg | satellite_z14.jpg | none),
SPIKE_DELAY, SPIKE_DIR, SPIKE_OSM.

## Data in this directory
- dem.f32 / dem16.png / meta.json: 1650x1633 heightmap, 7.43 m/px, cropped from 49 AWS Terrain Tiles
  (terrarium PNG, zoom 14, tiles x 2731-2737, y 6262-6268). Decoded with tools/stitch_terrarium.py
  (elev = R*256 + G + B/256 - 32768). Grid = Web-Mercator z14 pixel grid (lon linear per column,
  lat via inverse Mercator per row); meta.json has the exact pixel-center extent.
  dem16.png stores round(elev_m*10) as uint16. Validated against open-meteo: Lake Tahoe reads 1897-1900 m.
- hillshade_tex.png: hypsometric tint x hillshade (sun az 315, alt 45) at DEM resolution.
- satellite_z14.jpg / satellite_z15.jpg: Esri World Imagery tiles stitched on the SAME tile grid
  (z15 = 2x DEM resolution, 3300x3266). Spike-only: Esri World Imagery terms require attribution and
  are not a free redistribution license; a production app needs a licensed/attributed imagery source.
- Pistes/lifts come from ../../data/raw/heavenly_osm.json (OpenStreetMap, ODbL) parsed at runtime.

## How it works (Sources/)
- Geo.swift: DEM loader + bilinear sampling; local ENU projection (x = east, y = up, z = south).
- Terrain.swift: TerrainGrid downsamples the DEM by `stride`, builds one SCNGeometry (float32 SIMD
  vertex/normal/uv sources, UInt32 triangle element), applies the texture with UV = pixel centers.
  `surfaceHeight(lat:lon:)` reproduces the exact triangle-split interpolation so draped lines sit on
  the rendered surface. `ribbonGeometry` builds flat horizontal ribbons (triangle list) from polylines.
- ResortScene.swift: terrain node, one SCNNode per OSM piste way ("piste:<id>|<name>", 14 m wide,
  +4 m) colored by piste:difficulty, lifts as gray 8 m ribbons (+12 m), directional + ambient light,
  initial camera NNW of the resort looking south.
- SpikeView.swift: SCNView wrapper (allowsCameraControl orbit turntable, 4x MSAA, stats bar),
  NSClickGestureRecognizer -> SCNView.hitTest -> walk to the named piste node -> highlight yellow
  ("crossed off"); FPS counter via SCNSceneRendererDelegate; programmatic pick test + screenshot.

## Measured results (2026-11-01, Apple Silicon, 1280x800@2x window, 120 Hz display)
- Scene build 0.07 s: terrain 674,025 verts / 1,344,768 tris (stride 2), 165 piste ways + 23 lifts as
  13,362 draped points. 120 fps (display-capped) with rendersContinuously + 4x MSAA. run_stats_*.json.
- Picking: SCNView.hitTest at the projected midpoint of OSM way 313466575 "Gunbarrel" returns that node
  (5.7-27 ms with the 1.34M-tri terrain in the search); hit-test at view center after aiming the camera at
  it also returns it. projectPoint and hitTest share the same y convention (no flip).
- screenshot.png (hillshade), screenshot_satellite.png (Esri z15 drape), screenshot_closeup.png
  (California Lodge base, Gunbarrel selected in yellow) - real relief, draped ribbons follow the slope.
- Runtime is fully offline: DEM, textures and OSM JSON are local files; network only for data prep.
