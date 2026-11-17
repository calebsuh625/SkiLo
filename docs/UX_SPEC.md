# HeavenlyTracker — Product, UX and Data-Model Spec

Status: v1 draft, 2026-11-01. Owner: spec agent. Audience: the parallel build agents (data pipeline,
rating engine, map engine, screens, persistence) and the orchestrator.

Native SwiftUI macOS app, deployment target **macOS 15**, built with `swiftc`/`swift build` from the
Command Line Tools (no `xcodebuild`). Single user, offline-first, no accounts.

This document is the contract between agents. Type names, file paths, enum cases and JSON keys in
this document are normative; anything marked *(later)* is out of V1 scope.

---

## 0. One-paragraph product definition

HeavenlyTracker is a **ski progression tracker for Heavenly Mountain Resort** (South Lake Tahoe,
CA/NV). Every named trail gets a **1–100 difficulty rating** (not just green/blue/black), the user
keeps a **bucket list** of trails, **crosses them off on a 3D map**, logs runs, and watches a
**skill estimate (1–100)** climb over time with suggestions for what to ski next.

Design principles, in priority order:

1. **The map is the product.** Everything else exists to put state on the map and read it back.
2. **One number.** The 1–100 rating is the spine: map color, table sort, progression math,
   suggestions, badges all derive from it.
3. **Mac-native.** `NavigationSplitView`, `Table`, `.inspector`, toolbar, menu bar commands,
   keyboard shortcuts, undo, dark mode, `.searchable`. No custom chrome.
4. **Crossing something off must feel good.** One click from the map, visible animation, undoable.
5. **Engine-agnostic 3D.** The map UI talks to an abstract `MapEngine`; MapKit / SceneKit /
   MapLibre are interchangeable implementations.

---

## 1. Information architecture

### 1.1 Window layout

One main window (`WindowGroup`, single instance; `Cmd+N` disabled). Minimum 1000×640 pt,
default 1280×800 pt. Three columns:

```
┌──────────────┬───────────────────────────────────────────────┬──────────────────────┐
│ SIDEBAR      │ CONTENT (changes per section)                 │ INSPECTOR            │
│ 200–260 pt   │                                                │ 320–480 pt, toggle   │
│              │  toolbar: [section-specific] ... [search]      │ (selected trail)     │
│ ● Map        │                                                │                      │
│   Trails     │                                                │                      │
│   Bucket List│                                                │                      │
│   Progress   │                                                │                      │
│   Log        │                                                │                      │
│              │                                                │                      │
│ ──────────── │                                                │                      │
│ Skill  62    │                                                │                      │
│ ▓▓▓▓▓▓░░░░   │                                                │                      │
│ 41/126 done  │                                                │                      │
└──────────────┴───────────────────────────────────────────────┴──────────────────────┘
```

- `NavigationSplitView(sidebar:content:)` with `.navigationSplitViewStyle(.balanced)`.
- The **Inspector** is `.inspector(isPresented: $store.inspectorShown) { TrailInspector(...) }`
  attached to the content column. It is the *same* view in every section; it shows the currently
  selected trail (`store.selection`). When nothing is selected it shows an empty-state
  ("Select a trail on the map or in a table").
- The sidebar footer is a persistent **mini progress card**: current skill estimate, a progress bar
  of done/total, and a count. Clicking it navigates to Progress.

### 1.2 Sidebar sections

| Section      | Shortcut | SF Symbol              | Content column                                   |
|--------------|----------|------------------------|--------------------------------------------------|
| Map          | `Cmd+1`  | `map.fill`             | 3D map (section 2)                               |
| Trails       | `Cmd+2`  | `list.bullet.rectangle`| Sortable `Table` of all trails (section 3)       |
| Bucket List  | `Cmd+3`  | `star.fill`            | Ordered list + ring + suggested next (section 4) |
| Progress     | `Cmd+4`  | `chart.line.uptrend.xyaxis` | Charts, counts, streaks, badges (section 5) |
| Log          | `Cmd+5`  | `book.closed.fill`     | Run log grouped by ski day (section 6)           |

Badges in sidebar rows: Bucket List shows pending count (e.g. `Bucket List  7`); Log shows nothing.

### 1.3 Toolbar (per section)

Common, right-aligned: **search field** (`.searchable`, `Cmd+F` focuses it, scope = trail names,
also matches lift names on Map) and **Inspector toggle** (`sidebar.trailing`, `Cmd+Opt+I`).

| Section     | Leading / principal toolbar items                                                   |
|-------------|-------------------------------------------------------------------------------------|
| Map         | Camera preset menu (Overview / California / Nevada / Mott & Killebrew), Base style menu (Satellite / Terrain / Outline), Filter menu, Legend toggle, Fit-to-selection |
| Trails      | Filter menu, Group by (None / Area / Band), Column picker, "Mark Done" + "Bucket" buttons (enabled with selection) |
| Bucket List | "Add Trail…" (search popover), Sort (Manual / Rating ↑ / Rating ↓ / Area), Show crossed-off toggle |
| Progress    | Season picker (This season / All time), Range (30d / 90d / Season / All)             |
| Log         | "Log Run…" (`Cmd+L`), Ski Day picker, Export CSV *(later)*                            |

### 1.4 Global filter model

A single `TrailFilter` lives in `AppStore` and applies to **Map, Trails and Bucket List** identically
(so what you see in the table is what is highlighted on the map). The filter menu is the same control
in all three toolbars. An active filter shows a filled funnel icon and a "Clear filters" row.

```swift
struct TrailFilter: Equatable, Codable {
    var areas: Set<Area> = Set(Area.allCases)      // CA, NV
    var subAreas: Set<SubArea>? = nil              // nil = all; e.g. [.mottCanyon, .killebrewCanyon]
    var ratingRange: ClosedRange<Int> = 1...100
    var statuses: Set<TrailStatus> = Set(TrailStatus.allCases)
    var grooming: Set<Grooming>? = nil             // nil = all
    var gladedOnly: Bool = false
    var readyForMe: Bool = false                   // rating within progression engine's "ready" window
    var searchText: String = ""
    var isActive: Bool { self != TrailFilter(searchText: searchText) }
}
```

### 1.5 Keyboard shortcuts

| Shortcut            | Action                                              | Scope                 |
|---------------------|-----------------------------------------------------|-----------------------|
| `Cmd+1`…`Cmd+5`     | Switch sidebar section                              | global                |
| `Cmd+F`             | Focus search                                        | global                |
| `Cmd+Opt+I`         | Toggle Inspector                                    | global                |
| `Cmd+Ctrl+S`        | Toggle Sidebar (system default)                     | global                |
| `Cmd+D`             | Mark selected trail Done / Undo done (toggles)      | selection required    |
| `Cmd+B`             | Add to / remove from Bucket List                    | selection required    |
| `Cmd+L`             | Log a run on selected trail (opens sheet)           | selection optional    |
| `Cmd+Shift+R`       | Override rating… (opens popover in inspector)       | selection required    |
| `Cmd+0`             | Camera: Overview                                    | Map                   |
| `Cmd+Opt+1/2/3`     | Camera: California / Nevada / Mott & Killebrew      | Map                   |
| `Cmd+Shift+F`       | Fit camera to selected trail                        | Map                   |
| `Cmd+Shift+L`       | Toggle legend                                       | Map                   |
| `Esc`               | Clear selection (Map/Trails) / close sheet          | contextual            |
| `Return`            | Open selected trail in Inspector (show if hidden)   | Trails/Bucket/Log     |
| `Space`             | Quick Look-style preview popover of trail *(later)* | Trails                |
| `Delete`            | Remove from Bucket List / delete log entry          | Bucket / Log          |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / Redo any state change                    | global                |
| `Cmd+Shift+E`       | Export Data…                                        | global                |
| `Cmd+Shift+I`       | Import Data…                                        | global                |
| `Cmd+,`             | Settings                                            | global                |

### 1.6 Menu bar (`.commands`)

```
HeavenlyTracker   File                 Edit            View                     Trail                    Window   Help
  About             Export Data…  ⇧⌘E   Undo   ⌘Z      Map            ⌘1        Mark Done        ⌘D     (system) HeavenlyTracker Help
  Settings… ⌘,      Import Data…  ⇧⌘I   Redo  ⇧⌘Z      Trails         ⌘2        Add to Bucket    ⌘B              Data & Attribution (OSM/ODbL)
  (system)          ──────────────      Cut/Copy/Paste  Bucket List    ⌘3        Log Run…         ⌘L              Reveal Data Folder
                    Reveal Data File    Select All ⌘A   Progress       ⌘4        Override Rating… ⇧⌘R
                    in Finder                           Log            ⌘5        ───────────────
                    ──────────────                      ───────────────          Open in Apple Maps
                    Reload Trail Data                   Show Inspector ⌥⌘I       Copy Trail Name
                    (dev; re-reads bundled json)        Show Legend   ⇧⌘L
                                                        ───────────────
                                                        Camera ▸ Overview ⌘0
                                                                 California ⌥⌘1
                                                                 Nevada     ⌥⌘2
                                                                 Mott & Killebrew ⌥⌘3
                                                        Base Style ▸ Satellite / Terrain / Outline
                                                        Filters ▸ (same as toolbar filter menu)
```

The **Trail** menu items are disabled when `store.selection == nil`. "Mark Done" reads
"Mark Not Done" when the selected trail is already done.

### 1.7 Settings (`Cmd+,`)

Tabs: **General** (units: imperial/metric; default section at launch; confirm before marking done
from map: off), **Progression** (self-assessed starting level slider, decay window days),
**Data** (file path, export/import, "Reset all user data…" with confirmation), **About**.

### 1.8 First launch (onboarding)

A single sheet: "How would you rate yourself today?" — a 1–100 slider with the band ramp under it and
example anchor trails (`15 Maggie's`, `35 Olympic Downhill`, `55 Ellie's`, `72 Gunbarrel`,
`92 Snake Eyes`; the anchors come from the rating engine's output, not hardcoded). This value seeds
`UserProfile.selfAssessedStart` and the first point in the skill history. A second optional step:
"Backfill: I've already skied…" with checkboxes "all greens" / "all blues" (bulk Mark Done, flagged
`backfilled: true` so they don't count toward streaks). Skippable.

---

## 2. The 3D Map screen

### 2.1 Wireframe

```
┌ toolbar ─────────────────────────────────────────────────────────────────────────────────────┐
│ [Camera ▾ Overview] [Style ▾ Satellite] [Filter ▾ ●] [Legend ⌧] [⤢ Fit]      [🔍 Search  ] [▯]│
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                              │
│     ╱╲   ╱╲      3D terrain, satellite or terrain base, pitched camera ~55°                  │
│    ╱  ╲ ╱  ╲     trails drawn as colored polylines (ramp by rating) with casing              │
│   ╱    ╳    ╲    lifts as gray dashed lines with chair glyph at top                          │
│  ╱  ✓ ╱ ╲ ★  ╲   boundary as thin white dashed polygon                                       │
│ ╱    ╱   ╲    ╲  ✓ = done badge   ★ = bucket badge   (badges at trail midpoint)              │
│                                                                                              │
│  ┌ hover tooltip ──────────┐                                                                 │
│  │ Gunbarrel  ◆◆ 72        │                                                                 │
│  │ 0.9 mi · 1,560 ft · 31% │                                                                 │
│  └─────────────────────────┘                                                                 │
│                                                                                              │
│ ┌ legend ─────────────────────────┐             ┌ toast (after action) ────────────────────┐ │
│ │ 1 ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 100  │             │ ✓ Gunbarrel crossed off      [Undo]       │ │
│ │  ● green  ■ blue  ◆ black ◆◆ dbl│             └──────────────────────────────────────────┘ │
│ │  ✓ done   ★ bucket  — not yet   │                                                          │
│ │  ╌╌ lift  ┈┈ boundary           │                                                          │
│ └─────────────────────────────────┘   [Overview] [CA] [NV] [Mott/Killebrew]  ◁ camera chips  │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Overlays (legend, toast, camera chips, hover tooltip) are SwiftUI views layered **over** the engine's
`NSView` in a `ZStack`; the engine never draws UI chrome. That keeps the overlays identical across
engines.

### 2.2 Trail styling rules (the `TrailStyle` the UI hands to the engine)

Color is a function of the trail's **effective rating** (`override ?? computed`), see §8.1 ramp.

| Status / state         | Stroke                                  | Opacity | Width (pt @ overview → close) | Badge at midpoint                  |
|------------------------|-----------------------------------------|---------|-------------------------------|------------------------------------|
| Not done (default)     | ramp(rating), casing white 1 pt         | 1.0     | 2.5 → 5                       | none                               |
| Bucket                 | ramp(rating), casing `#FFD60A` 1.5 pt   | 1.0     | 3 → 6                         | `star.fill` yellow on dark disc    |
| Done                   | ramp(rating) desaturated 70%, lightness +15% | 0.55 | 2 → 4                         | `checkmark` white on `#34C759` disc|
| Filtered out           | `#8E8E93`                               | 0.15    | 1.5 → 3                       | none                               |
| Hovered (+)            | width ×1.3, casing ×2                   |         |                               | badge scales 1.15                  |
| Selected (+)           | width ×1.8, outer glow white 4 pt @ 60% | 1.0 (even if done) |                    | badge scales 1.3, name label shown |
| Unnamed connector ways | `#C7C7CC`, no casing                    | 0.5     | 1.5 → 2.5                     | none; not selectable in V1         |
| Lift                   | `#3A3A3C` dashed [6,4], casing white    | 0.9     | 1.5 → 3                       | `chair.lift`-style glyph at top terminal, name label at close zoom |
| Boundary               | white dashed [4,4]                      | 0.6     | 1                             | —                                  |

Width scales with camera distance so lines stay readable from Overview to close-up. Casing color
flips to `#1C1C1E` on the Outline base style (light background).

### 2.3 Selection → Inspector flow

1. Click on a trail (hit-test tolerance ≥ 8 pt around the polyline) → engine emits
   `didSelect(trailID)`.
2. `AppStore.selection = trailID`; the Inspector auto-shows if hidden (unless the user previously
   collapsed it in this session, tracked by `inspectorUserHidden`).
3. The trail renders in Selected style; a floating name label (`name · band symbol · rating`) is
   drawn by the overlay at the projected midpoint (engine provides `project(coordinate) -> CGPoint?`).
4. Inspector shows the trail (see §2.6). Status buttons are the primary actions.
5. Click on empty terrain or `Esc` → `didSelect(nil)` → selection cleared; Inspector keeps showing
   the last trail but in a "not selected" muted header *(V1: just clears to empty state)*.
6. Search on Map: typing filters a results popover under the field (name, band, rating, status);
   choosing a result selects it and runs `camera(fitting:)`.

Hover: engine emits `didHover(trailID?, at: CGPoint)`; the overlay shows the tooltip after 150 ms
delay, hides immediately on nil. Hover never changes selection.

### 2.4 Crossing off from the map ("the moment")

From the Inspector (or `Cmd+D` with a selection, or the trail's context menu on right-click):

- **Mark Done**:
  1. `AppStore.markDone(id)` registers an undo action and persists.
  2. Style transition: 250 ms the stroke flashes to white at width ×2.2, then eases (spring,
     response 0.45, damping 0.7) into the Done style; the check badge scales from 0 → 1.3 → 1.0.
     Implemented by the engine via `animateStatusChange(trailID, to: .done)`; engines that cannot
     animate just apply the final style (capability flag).
  3. `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)`.
  4. Toast at top-right of the map: "✓ Gunbarrel crossed off · Undo" (auto-dismiss 4 s;
     Undo = `undoManager.undo()`).
  5. If the trail was on the bucket list (`bucketedAt != nil`), the toast reads
     "★ Gunbarrel crossed off your bucket list" and the Bucket List badge count decrements.
  6. If no run is logged today for that trail, the toast has a second button "Log run…" which opens
     the Log Run sheet prefilled (date = today, trail = id).
  7. Milestone check runs; if a badge unlocks, a second toast "🏅 First Double Black" appears,
     clicking it navigates to Progress with the badge highlighted.
- **Add to Bucket List**: badge star scales in with the same spring; toast "★ Added to bucket list".
- **Mark Not Done** (undo-done): reverse animation, no haptic.

No confirmation dialogs. Everything is undoable; that is the safety net.

### 2.5 Filters, legend, camera presets

- **Filters**: the shared `TrailFilter` (§1.4). Filtered-out trails are drawn in the dim style (not
  hidden) so the terrain still reads as a ski area. "Only show ready for me" uses
  `ProgressionEngine.readyWindow`.
- **Legend** (bottom-left, toggle `Cmd+Shift+L`, remembered in `@AppStorage`): continuous ramp bar
  with band tick marks at 25/50/75 and band symbols, status glyph key, lift/boundary key. Hovering a
  band on the legend temporarily dims trails outside the band (preview; not a filter).
- **Camera presets** (`CameraPreset`), heading = direction the camera looks (0 = north):

| Preset            | Center (lat, lon)      | Distance | Heading | Pitch | Notes                                      |
|-------------------|------------------------|----------|---------|-------|--------------------------------------------|
| `.overview`       | 38.940, -119.912       | 14 km    | 180°    | 55°   | From over the lake looking south at both sides |
| `.california`     | 38.926, -119.922       | 6.5 km   | 165°    | 60°   | Gunbarrel/Face left, Sky/Canyon right      |
| `.nevada`         | 38.946, -119.894       | 7.5 km   | 200°    | 60°   | Stagecoach/Olympic/Dipper/Comet            |
| `.mottKillebrew`  | 38.930, -119.891       | 3.2 km   | 265°    | 62°   | From the east looking west into the chutes |
| `.fit(trailID)`   | trail bbox center      | computed | keep    | 60°   | Pads bbox by 30%                           |

Camera chips are also shown as small capsule buttons at the bottom-right of the map for mouse users.
The user's last camera is restored on launch (`CameraState` persisted in `@AppStorage`).

Base styles: `.satellite` (default; "hybrid with realistic elevation" in MapKit), `.terrain`
(muted hillshade), `.outline` (flat light background, trails only — fastest; also the fallback if an
engine cannot do 3D). Engines report which styles they support; unsupported entries are disabled.

### 2.6 Trail Inspector (shared by all sections)

```
┌ Inspector ────────────────────────────────┐
│ Gunbarrel                            ◆◆   │  name (title2, bold); band symbol
│ California · Gunbarrel/Face               │  area · subArea (secondary)
│                                           │
│  ┌──────┐  72 / 100   Double Black        │  rating pill: big number on ramp color
│  │  72  │  OSM: expert · moguls           │  secondary: osm difficulty · grooming · gladed
│  └──────┘  ✎ your override: 78            │  shown only if override exists
│                                           │
│ [ Not done | ★ Bucket | ✓ Done ]           │  segmented picker, bound to status
│ [ Log Run… ⌘L ]                           │
│                                           │
│ Length   0.9 mi     Vert   1,560 ft       │  stats grid (2×3)
│ Avg      31%        Max    44%            │
│ Top      8,250 ft   Bottom 6,690 ft       │
│                                           │
│ ▾ Elevation profile                       │  Swift Charts AreaMark, x = distance, y = elevation
│   ╭──╮                                    │  colored by local grade (ramp), hover shows grade
│   │  ╰─╮__                                │
│                                           │
│ ▾ Why 72?                                 │  rating breakdown (RatingBreakdown.components)
│   Base: OSM expert              +60       │  horizontal bars, sign-colored
│   Avg grade 31%                 +6        │
│   Max grade 44% (50 m window)   +4        │
│   Ungroomed moguls              +4        │
│   Length 0.9 mi                 −2        │
│   ─────────────────────────────────       │
│   Computed                       72       │
│   [Override rating…]  [Reset]             │
│                                           │
│ ▾ Your history                            │  timesSkied, firstDoneDate, last run, best confidence
│   Skied 3× · first Jan 14, 2026           │
│   Jan 14  firm  ★★★☆☆  "survived"         │  last 5 runs, "Show all in Log →"
│                                           │
│ ▾ Notes                                   │  TextEditor, autosaves (debounced)
│   ┌─────────────────────────────┐         │
│   │ Skier's left stays softer    │         │
│   └─────────────────────────────┘         │
│ ▸ Photos (0)                 *(later)*    │
│                                           │
│ OSM ways 123, 456 · ODbL                  │  footer, tiny, monospaced
└───────────────────────────────────────────┘
```

Override popover (`Cmd+Shift+R`): slider 1–100 with ramp track, live band symbol, required note
field ("why?"), Save/Cancel. Saving sets `ratingOverride` and `ratingOverrideNote`; the map recolors
immediately.

### 2.7 The abstract `MapEngine` interface

The Map screen depends only on this. Implementations live in `Sources/MapEngines/{MapKitEngine,
SceneKitEngine, MapLibreEngine}` and register via `MapEngineRegistry`. Swap by a Settings
"Map engine" picker (dev-only in V1).

```swift
// Sources/HeavenlyCore/MapEngine.swift  — engine-agnostic

import Foundation
import AppKit

struct GeoCoordinate: Codable, Hashable { var lat: Double; var lon: Double; var ele: Double? }

/// Static scene: everything that only changes when trail data reloads.
struct MapScene {
    var trails: [TrailGeometry]          // id + polylines (one per OSM way) + midpoint
    var lifts: [LiftGeometry]            // id + polyline + top/bottom terminal
    var boundary: [[GeoCoordinate]]      // outer rings of the winter_sports multipolygon
    var bounds: GeoBounds                // min/max lat/lon of everything, for fit
}
struct TrailGeometry: Identifiable { let id: Trail.ID; let polylines: [[GeoCoordinate]]; let midpoint: GeoCoordinate; let isSelectable: Bool }
struct LiftGeometry:  Identifiable { let id: Lift.ID;  let polyline: [GeoCoordinate]; let name: String; let kind: LiftKind }

/// Per-trail dynamic style. The UI computes this from status+filter+selection; the engine just draws it.
struct TrailStyle: Equatable {
    enum Badge: Equatable { case none, done, bucket }
    enum Emphasis: Equatable { case normal, dimmed, hovered, selected }
    var color: RGBA           // ramp(rating) already applied (and desaturated for done)
    var casing: RGBA
    var opacity: Double
    var baseWidth: Double     // pt at overview; engine scales with camera distance
    var dash: [Double]?       // nil = solid
    var badge: Badge
    var emphasis: Emphasis
    var label: String?        // shown when selected (or at close zoom if engine supports labels)
}
struct RGBA: Equatable, Codable { var r, g, b, a: Double }

enum CameraPreset: Equatable { case overview, california, nevada, mottKillebrew, fit(Trail.ID) }
struct CameraState: Codable, Equatable { var center: GeoCoordinate; var distanceM: Double; var headingDeg: Double; var pitchDeg: Double }
enum MapBaseStyle: String, CaseIterable, Codable { case satellite, terrain, outline }

struct MapEngineCapabilities: OptionSet {
    let rawValue: Int
    static let terrain3D      = Self(rawValue: 1 << 0)   // real elevation mesh
    static let pitch          = Self(rawValue: 1 << 1)
    static let hover          = Self(rawValue: 1 << 2)
    static let badges         = Self(rawValue: 1 << 3)   // can draw midpoint glyphs itself
    static let animateStyle   = Self(rawValue: 1 << 4)
    static let labels         = Self(rawValue: 1 << 5)
    static let offline        = Self(rawValue: 1 << 6)   // no network needed for base
}

protocol MapEngineDelegate: AnyObject {
    func mapEngine(_ engine: MapEngine, didSelect trailID: Trail.ID?)          // nil = cleared
    func mapEngine(_ engine: MapEngine, didHover trailID: Trail.ID?, at point: CGPoint?)
    func mapEngine(_ engine: MapEngine, cameraDidChange camera: CameraState)
    func mapEngine(_ engine: MapEngine, didFinishLoading ok: Bool, error: Error?)
}

protocol MapEngine: AnyObject {
    static var displayName: String { get }
    var capabilities: MapEngineCapabilities { get }
    var supportedBaseStyles: [MapBaseStyle] { get }
    var delegate: MapEngineDelegate? { get set }

    /// The NSView to host. Called once; the UI wraps it in an NSViewRepresentable.
    func makeView() -> NSView

    // Inputs
    func load(scene: MapScene)                                   // (re)build geometry
    func apply(styles: [Trail.ID: TrailStyle])                   // full style map; engine diffs
    func setSelection(_ id: Trail.ID?)                           // visual only; selection state lives in AppStore
    func setBaseStyle(_ style: MapBaseStyle)
    func setCamera(_ preset: CameraPreset, animated: Bool)
    func setCamera(_ state: CameraState, animated: Bool)
    func animateStatusChange(_ id: Trail.ID, to badge: TrailStyle.Badge)  // no-op if !animateStyle

    // Queries used by SwiftUI overlays
    func currentCamera() -> CameraState
    func project(_ c: GeoCoordinate) -> CGPoint?                 // nil if off-screen/behind terrain
}
```

Contract notes for implementers:
- `apply(styles:)` is called on every status/filter/selection change (≤ 165 entries); must be cheap
  (diff against last applied; only touch changed trails).
- Selection/hover hit-testing is the engine's job (it owns the projection). Tolerance ≥ 8 pt.
- If `badges` is **not** in capabilities, the overlay draws badges itself using `project(midpoint)`
  every frame the camera changes (`cameraDidChange`). The MapKit engine may use this path in V1.
- If `terrain3D` is unavailable (e.g. offline), the engine must still render polylines on a flat
  `.outline` style — the app must never show a blank map.
- Engine must not import `HeavenlyCore` models beyond this file; it never sees `UserTrailState`.

Style computation (UI side, `TrailStyleBuilder.style(for trail, state, filter, selection, hover, base)`)
is a pure function and unit-tested; it is where §2.2 lives.

---

## 3. Trails screen

### 3.1 Wireframe

```
┌ toolbar ───────────────────────────────────────────────────────────────────────────────────────┐
│ [Filter ▾ ●] [Group ▾ None] [Columns ▾]  [✓ Mark Done] [★ Bucket]            [🔍 Search ] [▯] │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 126 trails · 41 done · 7 bucketed · filter: NV, 50–100                     (status bar text)   │
├─────┬────────────────────┬──────┬─────┬─────┬──────┬────────┬────────┬───────┬─────┬────┬──────┤
│ St  │ Name            ▲  │ Area │ Rtg │ Band│ OSM  │ Length │ Vert   │ Avg % │ Max%│Grm │ Gld  │
├─────┼────────────────────┼──────┼─────┼─────┼──────┼────────┼────────┼───────┼─────┼────┼──────┤
│ ✓   │ Big Dipper         │ NV   │ 38  │ ■   │ ■    │ 1.4 mi │ 1,020  │ 17    │ 29  │ —  │      │
│ ★   │ Bill's             │ NV   │ 91  │ ◆◆  │ ◆◆   │ 0.3 mi │   720  │ 46    │ 58  │ —  │ ●    │
│     │ Boulder Bowl       │ NV   │ 12  │ ●   │ ●    │ 0.6 mi │   380  │ 11    │ 16  │ grm│      │
│     │ Cascade            │ NV   │ 44  │ ■   │ ■    │ 0.5 mi │   560  │ 22    │ 33  │ mgl│      │
│ ✓   │ Comet              │ NV   │ 33  │ ■   │ ■    │ ...                                        │
└─────┴────────────────────┴──────┴─────┴─────┴──────┴────────┴────────┴───────┴─────┴────┴──────┘
```

- SwiftUI `Table(sortOrder:)` with `KeyPathComparator`s; multi-selection enabled.
- Row double-click or `Return` → shows Inspector; single click → selection (Inspector updates if
  shown). Right-click context menu: Mark Done / Not Done, Add to / Remove from Bucket, Log Run…,
  Show on Map (switches to Map and runs `.fit(id)`), Override Rating…, Copy Name.
- Multi-select + Mark Done = bulk backfill (one undo group, `backfilled: true` on each state).

### 3.2 Columns

| Column    | Key path / value                              | Sort | Default visible | Notes |
|-----------|-----------------------------------------------|------|-----------------|-------|
| Status    | `state.status` glyph (`✓`, `★`, blank)        | yes  | yes | sorts done→bucket→notDone |
| Name      | `trail.name`                                  | yes  | yes | localized compare |
| Area      | `trail.area` (CA/NV) + subArea tooltip        | yes  | yes | |
| Rating    | `effectiveRating` — number in a small ramp-colored pill | yes | yes | override shows ✎ |
| Band      | derived from effective rating (symbol)        | yes  | yes | ● ■ ◆ ◆◆ |
| OSM       | `trail.osmDifficulty` as symbol               | yes  | yes | source color; shows disagreement with Band at a glance |
| Length    | `trail.lengthM` (unit-aware)                  | yes  | yes | |
| Vert      | `trail.vertM`                                 | yes  | yes | |
| Avg grade | `trail.avgGradePct`                           | yes  | yes | |
| Max grade | `trail.maxGradePct`                           | yes  | yes | |
| Grooming  | `trail.grooming` (groomed/moguls/backcountry/—)| yes | yes | |
| Gladed    | `trail.gladed` dot                            | yes  | yes | |
| Lift      | `trail.liftName` (nearest serving lift)       | yes  | no  | |
| Times     | `state.timesSkied`                            | yes  | no  | |
| First done| `state.firstDoneDate`                         | yes  | no  | |
| Top / Bottom elev | `trail.elevTopM` / `elevBottomM`      | yes  | no  | |

Column visibility is remembered in `@AppStorage("trails.columns")`. Group-by Area or Band uses
`Table` sections with header counts ("Nevada · 84 · 31 done").

### 3.3 Trail detail

V1: the Inspector (§2.6) *is* the detail; the Inspector can be dragged to 480 pt so the elevation
chart gets room. *(later)*: full-page detail replacing the table (`navigationDestination`), with
a large profile, a mini 3D map of just that trail, photos grid.

Elevation profile chart (Swift Charts):
- `AreaMark(x: distance, y: elevation)` with `.interpolationMethod(.catmullRom)`, foreground =
  `LinearGradient` of the ramp evaluated per segment grade (so steep bits look red), plus a
  `LineMark` on top. Y axis padded 5%; x in mi/km per unit setting.
- Hover: `chartOverlay` with a vertical rule and a callout "0.42 mi · 7,610 ft · 38%".
- Data source: `trail.profile: [ProfileSample]` (resampled every ~20 m by the pipeline).

### 3.4 Rating breakdown and override

`RatingBreakdown` comes from the rating engine (see §7.4) and is rendered as rows of
`label · bar · signed points`. The UI makes no assumptions about which components exist; it renders
whatever the engine returns, in order, then a Total row. The last row shows the override if any
with its note, and `Reset` clears it.

### 3.5 Notes/photos

Notes: `UserTrailState.notes` (plain text), autosave 600 ms after the last keystroke. Photos
*(later)*: files copied into `~/Library/Application Support/HeavenlyTracker/photos/<trailID>/`,
referenced by filename in `UserTrailState.photoFilenames`.

---

## 4. Bucket List screen

### 4.1 Wireframe

```
┌ toolbar ──────────────────────────────────────────────────────────────────────────────────────┐
│ [+ Add Trail…] [Sort ▾ Manual] [Show crossed-off ⌧]                          [🔍 Search ] [▯] │
├───────────────────────────────────────────────────────────────────────────────────────────────┤
│  ┌───────────┐   Bucket List                                                                  │
│  │   ◯ 4/11  │   4 crossed off · 7 to go · 2,900 ft of vert waiting                          │
│  │  ring 36% │   Suggested next: ★ Ellie's (55) — "right at your level (skill 58)"  [Show ▸]  │
│  └───────────┘                                                                                │
│                                                                                               │
│  TO SKI                                                                                       │
│  ≡  1  ★ Ellie's              ◆  55   CA · moguls      ready        [✓ Done]  [⋯]             │
│  ≡  2  ★ Sky Canyon           ◆  61   CA · moguls      stretch +3   [✓ Done]  [⋯]             │
│  ≡  3  ★ Gunbarrel            ◆◆ 72   CA · moguls      stretch +14  [✓ Done]  [⋯]             │
│  ≡  4  ★ Milky Way Bowl       ◆  66   NV · moguls      stretch +8   [✓ Done]  [⋯]             │
│  ...                                                                                          │
│  CROSSED OFF                                                                                  │
│     ✓  ~~Big Dipper~~         ■  38   NV   done Jan 14, 2026                                  │
│     ✓  ~~Comet~~              ■  33   NV   done Jan 14, 2026                                  │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `List` with `.onMove` (drag handle `≡` visible in Manual sort). Order persisted as
  `UserData.bucketOrder: [Trail.ID]`. Sorting by rating/area is a view sort and does not rewrite
  manual order.
- Each row: rank, name, band symbol, rating pill, area · grooming, **readiness chip** from the
  progression engine (`ready` green / `stretch +n` orange / `big stretch +n` red / `below you` gray),
  inline `Done` button (same animation + toast as the map; also triggers the strike-through
  animation: text strikes through left→right over 300 ms, row slides to the Crossed Off section).
- `⋯` menu: Show on Map, Log Run…, Move to top, Remove from list.
- Progress ring: `done-bucketed / all-bucketed`, ramp-colored arc by average rating of the list.
- **Suggested next** card: `ProgressionEngine.suggestedNext(bucket:)` — the lowest-rated pending
  bucket item within the ready window; else the nearest stretch with a one-line reason string
  supplied by the engine. "Show ▸" selects it and switches to Map `.fit(id)`.
- "+ Add Trail…" opens a popover with a search field and a list of not-bucketed, not-done trails
  (name · band · rating · readiness) with multi-select and an "Add" button.
- Empty state: "Your bucket list is empty. Star trails on the map or in Trails, or try these:"
  followed by 5 engine suggestions (`readyFor` top 5).

---

## 5. Progress screen

### 5.1 Wireframe

```
┌ toolbar ──────────────────────────────────────────────────────────────────────────────────────┐
│ [Season ▾ 2025–26] [Range ▾ Season]                                               [🔍 ] [▯]  │
├───────────────────────────────────────────────────────────────────────────────────────────────┤
│ ┌ Skill ───────────────┐ ┌ Done ────────────┐ ┌ Days on snow ───┐ ┌ New-trail streak ───────┐ │
│ │  58  ▲ +6 this season│ │ 41 / 126   33%   │ │ 9  (season)     │ │ 3 days  (best 5)        │ │
│ │  ◆ Black             │ │ CA 20/43 NV 21/84│ │ 18 (all time)   │ │                         │ │
│ └──────────────────────┘ └──────────────────┘ └─────────────────┘ └─────────────────────────┘ │
│                                                                                               │
│ ┌ Skill estimate over time ───────────────────────────────────────────────────────────────┐   │
│ │100┤                                                                                     │   │
│ │ 75┤ · · · · · · · · · · · · · · · · · · · · · · · · · · · · · · · · ◆◆ band guide       │   │
│ │ 50┤          ╭──────╮        ╭────╯                                                     │   │
│ │ 25┤ ●────────╯      ╰────────╯      ← LineMark + shaded confidence band; points = ski days│   │
│ │  0┼──────┬──────┬──────┬──────┬──────┬                                                  │   │
│ │   Dec    Jan    Feb    Mar    Apr                                                       │   │
│ └─────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                               │
│ ┌ Completed runs by rating ───────────────┐ ┌ Ready for you ──────────────────────────────┐   │
│ │ ▁▃▆█▇▅▂▁░░   bars = done, outline = all│ │ ◆ Ellie's 55 · CA · moguls          [Map ▸] │   │
│ │ 1-10 11-20 … 91-100 (ramp colored)      │ │ ◆ Sky Canyon 61 · CA                [Map ▸] │   │
│ │ hover: "41–50: 9 of 22 done"            │ │ ◆ Pistol 59 · CA · moguls           [Map ▸] │   │
│ └─────────────────────────────────────────┘ │ … (5)                      [Add all to bucket]│   │
│                                             └─────────────────────────────────────────────┘   │
│ ┌ Milestones ──────────────────────────────────────────────────────────────────────────────┐   │
│ │ [🏅 First Green ✓] [🏅 First Blue ✓] [🏅 First Black ✓] [◇ First Double Black] [◇ Gunbarrel]│   │
│ │ [◇ All Greens 14/17] [◇ All Blues 28/75] [◇ Mott Canyon] [◇ Killebrew] [◇ Both States in a Day]│
│ └──────────────────────────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Content details

- **Skill line chart**: one `SkillPoint` per ski day (plus the onboarding seed). `LineMark` with
  `AreaMark` for `low…high`; `RuleMark`s at 25/50/75 labelled with band symbols; `PointMark` per
  ski day, hover shows "Jan 14 · 52 (±6) · 7 runs, best Gunbarrel 72 ★★★". Y domain 0…100.
- **Histogram**: 10 bins by rating decile; `BarMark` for done count, `BarMark` with
  `.opacity(0.15)` for total trails in that bin (stacked behind). Colors from the ramp at the bin
  midpoint. Clicking a bin applies a rating-range filter and jumps to Trails.
- **Counts**: done/total, by area (CA/NV), by band, plus total vert skied (sum over log).
- **Streaks**: *Days on snow* (count of ski days in range) and *New-trail streak* (consecutive ski
  days — not calendar days — each containing ≥ 1 first-time trail; `backfilled` states excluded).
- **Ready for you**: `ProgressionEngine.readyFor(limit: 5)`; `[Add all to bucket]` bulk action.
- **Milestones**: `Milestone` registry (§7.6); unlocked show date, locked show progress fraction
  where meaningful. Clicking shows the predicate in words ("Mark every green trail done").

---

## 6. Log screen

### 6.1 Wireframe

```
┌ toolbar ──────────────────────────────────────────────────────────────────────────────────────┐
│ [+ Log Run… ⌘L] [Ski Day ▾ All]                                                  [🔍 ] [▯]    │
├───────────────────────────────────────────────────────────────────────────────────────────────┤
│ ▾ Sat Jan 17, 2026 · "Bluebird after storm" · powder · 11 runs · 9,400 ft · top 72   [Edit day]│
│    10:05  Gunbarrel          ◆◆ 72  × 1.00 powder   ★★★☆☆  "legs gone by the bottom"    NEW   │
│    10:40  Ellie's            ◆  55  × 1.00 powder   ★★★★☆                                     │
│    11:10  Ellie's            ◆  55  × 1.00 powder   ★★★★★                                     │
│    …                                                                                           │
│ ▾ Wed Jan 14, 2026 · firm · 7 runs · 6,100 ft · top 52                              [Edit day]│
│    …                                                                                           │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `List` with sections = `SkiDay`s (derived by grouping entries by local calendar day, newest
  first). Section header shows day title, day conditions, run count, total vert, max rating, and
  an `Edit day` button (title, conditions, notes).
- Rows: time, trail name (click → selects trail in Inspector), band + rating, conditions chip with
  its multiplier, confidence stars, notes (truncated), `NEW` tag if this entry was the trail's first.
- Row context menu: Edit…, Duplicate (same trail, now), Show on Map, Delete (`Delete` key, undoable).
- Search filters by trail name and notes.

### 6.2 Log Run sheet (quick-add)

Opened from: toolbar, `Cmd+L`, Inspector "Log Run…", map toast "Log run…", Bucket `⋯` menu, Trails
context menu. Fields:

```
┌ Log a run ──────────────────────────────────────┐
│ Trail      [ Gunbarrel                  ▾🔍 ]    │  prefilled from selection; searchable picker
│ When       [ Today ▾ ]  [ 10:05 ]                │  date picker; defaults to now
│ Conditions [groomed][packed][powder][chopped]    │  segmented/chips → Conditions enum
│            [firm/icy][slush][moguls][variable]   │
│ Confidence [ ★ ★ ★ ☆ ☆ ]   "OK, in control"      │  1–5 with a caption per level
│ Notes      [                                ]    │
│ ☑ Mark trail as done                             │  default on if not done
│                                [Cancel] [Log ⏎]  │
└──────────────────────────────────────────────────┘
```

Confidence captions: 1 "Survived", 2 "Sketchy", 3 "OK, in control", 4 "Comfortable", 5 "Owned it".
Submitting appends a `RunLogEntry`, increments `timesSkied`, sets `firstDoneDate` if needed, marks
done if checked (one undo group), and shows the toast.

### 6.3 Conditions → multiplier

| `Conditions` case | Label        | Multiplier | Rationale                                     |
|-------------------|--------------|------------|-----------------------------------------------|
| `.groomed`        | Groomed      | 1.00       | baseline                                      |
| `.packedPowder`   | Packed       | 1.00       | baseline                                      |
| `.powder`         | Powder       | 0.95       | forgiving on steeps                           |
| `.chopped`        | Chopped/crud | 1.10       |                                               |
| `.firm`           | Firm/icy     | 1.15       | hardest version of any trail                  |
| `.slush`          | Slush/spring | 1.05       |                                               |
| `.moguls`         | Bumped up    | 1.10       | for trails not already rated as mogul runs    |
| `.variable`       | Variable/wind| 1.10       |                                               |

Effective difficulty of a run = `effectiveRating × multiplier`, clamped 1…100. The multipliers are a
constant table in `Conditions.multiplier`; the progression engine consumes them.

---

## 7. Data model and persistence

All types in `Sources/HeavenlyCore` (a SwiftPM library target with no AppKit/SwiftUI imports, so the
rating engine, progression engine and pipeline validators can be unit-tested headless).

### 7.1 Static catalog (bundled `trails.json`)

Produced by the data pipeline (`tools/build_trails.py` or Swift script) from
`data/raw/heavenly_osm.json` + elevation sampling. Shipped as `Resources/trails.json`; never written
by the app.

```swift
struct TrailCatalog: Codable {
    var schemaVersion: Int            // 1
    var generatedAt: Date
    var source: Provenance            // {"source":"OpenStreetMap via Overpass API","license":"ODbL 1.0","fetched":"2026-11-01"}
    var trails: [Trail]
    var lifts: [Lift]
    var boundary: [[GeoCoordinate]]   // outer rings
    var ratingEngineVersion: String   // e.g. "rating-1.0" — breakdowns are precomputed by the pipeline
}

enum Area: String, Codable, CaseIterable { case california = "CA", nevada = "NV" }
enum SubArea: String, Codable, CaseIterable {
    case gunbarrelFace, skyCanyonPowderbowl, tamarackTop,            // CA
    case dipperComet, olympicStagecoach, boulderGalaxyNorthBowl,     // NV
    case mottCanyon, killebrewCanyon                                  // NV expert canyons
}
enum OSMDifficulty: String, Codable { case easy, intermediate, advanced, expert, unknown }
enum Grooming: String, Codable { case groomed /*classic*/, moguls, backcountry, unknown }
enum Band: Int, Codable, CaseIterable {        // derived from rating, never stored
    case green = 0, blue, black, doubleBlack
    static func of(_ rating: Int) -> Band { rating < 25 ? .green : rating < 50 ? .blue : rating < 75 ? .black : .doubleBlack }
    var symbol: String { ["circle.fill", "square.fill", "diamond.fill", "diamond.fill.2"][rawValue] } // ◆◆ rendered as two diamonds
}

struct Trail: Codable, Identifiable, Hashable {
    typealias ID = String              // stable slug: "t-" + slugified name, e.g. "t-gunbarrel", "t-the-y", "t-100-saddle"
    let id: ID
    let name: String
    let osmWayIDs: [Int]               // all ways merged into this trail (same name)
    let area: Area
    let subArea: SubArea
    let liftName: String?              // nearest serving lift (by top terminal to trail top)
    let osmDifficulty: OSMDifficulty
    let grooming: Grooming
    let gladed: Bool
    let oneway: Bool
    let geometry: [[GeoCoordinate]]    // one polyline per OSM way, with ele filled by the pipeline
    let midpoint: GeoCoordinate        // for badges/labels (midpoint of the longest polyline by distance)
    let lengthM: Double                // 3D length, all polylines summed
    let vertM: Double                  // elevTop − elevBottom
    let elevTopM: Double
    let elevBottomM: Double
    let avgGradePct: Double            // vertM / horizontal length × 100
    let maxGradePct: Double            // steepest 50 m window
    let profile: [ProfileSample]       // resampled ~20 m, along the longest continuous polyline
    let rating: RatingBreakdown        // computed 1–100 with components (engine output, precomputed)
}
struct ProfileSample: Codable, Hashable { var distanceM: Double; var elevationM: Double; var gradePct: Double }

enum LiftKind: String, Codable { case chairLift = "chair_lift", gondola, cableCar = "cable_car", magicCarpet = "magic_carpet", ropeTow = "rope_tow" }
struct Lift: Codable, Identifiable, Hashable {
    typealias ID = String              // "l-" + osm id
    let id: ID; let osmWayID: Int; let name: String; let kind: LiftKind
    let polyline: [GeoCoordinate]; let area: Area
}
```

Catalog rules:
- One `Trail` per **unique name** (126). Ways with the same name are merged; the 34 unnamed
  `piste:type=downhill` ways are emitted separately in `catalog.connectors: [[GeoCoordinate]]`
  (rendered dim, not selectable, not counted).
- `Area` by the CA/NV oblique state line through the trail centroid
  (`lon_border(lat) = -(120 − 1.342·(39 − lat))`; centroid east of it is NV). On the raw data this
  gives **43 CA / 83 NV**. Trails whose centroid is within 0.004° of the line (verified with jq):
  Cascade, Dipper Line, Milky Way, Milky Way Bowl, Sam's Dream, Sand Dunes (all NV by the rule) and
  Tamarack Woods (CA). Those must be checked against the official trail map and fixed in
  `data/overrides/trail_overrides.json` (`{"t-cascade": {"area": "CA"}}` style). The pipeline
  owner decides; the app just reads `area`.
- `SubArea` by nearest lift top terminal, except the two expert canyons: `expert`/`advanced` trails
  with centroid inside lat 38.924…38.937, lon ≥ −119.8955 (the Mott Canyon chair's catchment) are
  `mottCanyon` when centroid lat ≥ 38.9287, else `killebrewCanyon`. On the raw data this yields
  mottCanyon = Bill's, Ernie's, Hemlock, Hully Gully, Mott Canyon Trail, North 40, On Hold,
  Pac-Man, Pinenuts, Promised Land, Rim Trail, Snake Eyes, Southern Comfort, Sweetwater, The "Y",
  Under the Gun, Widow Maker (17); killebrewCanyon = Bobs Boulevard, Boundry Chutes, Meadows,
  Outer Limits, Pipeline, Ramarah's, Stateline, The Fingers (8). This is a geometric heuristic,
  not ground truth — Pac-Man, Under the Gun, Sweetwater and Bobs Boulevard sit within 0.0005° of
  the split; verify against the official map and correct via the same override file.
- `trail.rating` is the engine's output. The app shows `rating.total` as "computed".

### 7.2 User data (persisted)

```swift
enum TrailStatus: String, Codable, CaseIterable { case notDone, bucket, done }

struct UserTrailState: Codable, Equatable {
    var status: TrailStatus = .notDone
    var bucketedAt: Date? = nil        // kept after status becomes .done → "crossed off" in Bucket List
    var firstDoneDate: Date? = nil
    var lastDoneDate: Date? = nil
    var timesSkied: Int = 0            // incremented by RunLog entries (and +1 on a manual Mark Done with no entry that day)
    var backfilled: Bool = false       // bulk-marked during onboarding; excluded from streaks/skill history
    var ratingOverride: Int? = nil     // 1…100
    var ratingOverrideNote: String? = nil
    var notes: String = ""
    var photoFilenames: [String] = []  // (later)
    var isEmpty: Bool { self == UserTrailState() }   // pruned on save
}

enum Conditions: String, Codable, CaseIterable { case groomed, packedPowder, powder, chopped, firm, slush, moguls, variable
    var multiplier: Double { /* table in §6.3 */ } }

struct RunLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var trailID: Trail.ID
    var date: Date                     // full timestamp
    var conditions: Conditions
    var confidence: Int                // 1…5
    var notes: String
    var isFirstTime: Bool              // set at creation; drives the NEW tag and streaks
}

struct SkiDayMeta: Codable, Equatable {     // optional per-day info; key = "yyyy-MM-dd" local
    var title: String = ""
    var conditions: Conditions? = nil
    var notes: String = ""
}

struct SkillPoint: Codable, Equatable { var date: Date; var value: Double; var low: Double; var high: Double; var runCount: Int }

struct UserProfile: Codable, Equatable {
    var selfAssessedStart: Int = 30           // from onboarding
    var startDate: Date
    var units: Units = .imperial
    var skillHistory: [SkillPoint] = []       // cache; recomputed from log on load, persisted for export readability
    var unlockedMilestones: [String: Date] = [:]   // milestone id → unlock date
}

struct UserData: Codable {
    var schemaVersion: Int = 1
    var appVersion: String
    var createdAt: Date
    var updatedAt: Date
    var profile: UserProfile
    var trailStates: [Trail.ID: UserTrailState]
    var bucketOrder: [Trail.ID]               // manual order; must be a subset of states with bucketedAt != nil
    var runLog: [RunLogEntry]
    var skiDays: [String: SkiDayMeta]
}
```

Invariants (enforced in `AppStore` mutators, checked by `UserData.validate()` on load):
- `status == .bucket ⇒ bucketedAt != nil`; `status == .done ⇒ firstDoneDate != nil`.
- `bucketOrder` contains every id with `status == .bucket` exactly once; done-but-bucketed ids may
  also be present (they sort into Crossed Off); unknown ids (trail removed from catalog) are dropped
  on load with a log line, never crash.
- Trail ids in `trailStates`/`runLog` that are not in the catalog are kept (not deleted) so an
  updated catalog can re-link them; the UI shows "Unknown trail" rows in the Log.

### 7.3 `AppStore` (observable application state)

```swift
@Observable @MainActor final class AppStore {
    let catalog: TrailCatalog
    private(set) var userData: UserData
    var filter = TrailFilter()
    var selection: Trail.ID?
    var hover: Trail.ID?
    var section: SidebarSection = .map
    var inspectorShown = true
    var cameraRequest: CameraPreset?          // consumed by MapScreen
    var toast: Toast?

    // Derived
    func state(for id: Trail.ID) -> UserTrailState
    func effectiveRating(_ t: Trail) -> Int { state(for: t.id).ratingOverride ?? t.rating.total }
    var skiDays: [SkiDay]                     // grouped from runLog
    // Mutations (all register undo via UndoManager, then schedule save)
    func markDone(_ id: Trail.ID, on date: Date = .now)
    func markNotDone(_ id: Trail.ID)
    func toggleBucket(_ id: Trail.ID)
    func moveBucket(from: IndexSet, to: Int)
    func logRun(_ entry: RunLogEntry, alsoMarkDone: Bool)
    func deleteRun(_ id: UUID)
    func setOverride(_ id: Trail.ID, rating: Int?, note: String?)
    func setNotes(_ id: Trail.ID, _ text: String)
}
```

### 7.4 Rating engine interface

```swift
struct RatingComponent: Codable, Hashable { let key: String; let label: String; let points: Double; let detail: String }
struct RatingBreakdown: Codable, Hashable {
    let total: Int                         // 1…100, rounded, clamped
    let components: [RatingComponent]      // ordered; sum ≈ total (engine may clamp)
    let engineVersion: String
}
protocol RatingEngine { static var version: String { get }; func rate(_ features: TrailFeatures) -> RatingBreakdown }
```

Expected component keys (so the UI can give them icons): `base` (OSM difficulty anchor),
`avgGrade`, `maxGrade`, `gradeVariance`, `length`, `vert`, `grooming`, `gladed`, `exposure`,
`manual` (pipeline adjustment with a reason). Unknown keys render with a generic icon. The band
anchors the engine should respect: easy → 1–24, intermediate → 25–49, advanced → 50–74,
expert → 75–100, with grade/grooming/glades moving a trail within its band and allowed to spill
≤ 8 points across a boundary when the physical data clearly disagrees with the OSM color.

### 7.5 Progression engine interface

```swift
struct SkillEstimate { var value: Double; var low: Double; var high: Double; var basisRuns: Int }
struct Readiness { enum Kind { case belowYou, ready, stretch, bigStretch }; var kind: Kind; var delta: Int; var reason: String }

protocol ProgressionEngine {
    func skillHistory(profile: UserProfile, log: [RunLogEntry], catalog: TrailCatalog, overrides: [Trail.ID: Int]) -> [SkillPoint]
    func currentSkill(...) -> SkillEstimate
    func readiness(for trail: Trail, skill: SkillEstimate) -> Readiness
    func readyFor(limit: Int, ...) -> [Trail.ID]
    func suggestedNext(bucket: [Trail.ID], ...) -> (Trail.ID, reason: String)?
    var readyWindow: ClosedRange<Int> { get }   // relative to skill, e.g. -3...7
}
```

V1 default algorithm (`DefaultProgressionEngine`, deterministic, pure):
- For each run: `e = effectiveRating × conditions.multiplier`; mastery `m = e + 4·(confidence − 3)`.
- Skill on ski day *d*: weighted 80th percentile of `m` over runs in the trailing 60 days, weight
  `0.5^(ageDays/30)`; if < 3 runs, `max(m) − 5`; if none, `profile.selfAssessedStart`.
  Smoothing: `skill(d) = max(raw, 0.9·skill(d−1))`. Clamp 1…100.
- Interval: `± (10 − min(basisRuns, 7))`.
- Readiness: `delta = rating − round(skill)`; `≤ −8 belowYou`, `−8 < delta ≤ 7 ready`,
  `7 < delta ≤ 15 stretch`, `> 15 bigStretch`.
- `readyFor`: not-done, filter-respecting trails with `ready`, sorted by `|delta − 3|` then name.
- `suggestedNext`: pending bucket items with `ready` (lowest delta ≥ 0 first), else the smallest
  stretch. Reason strings: "right at your level (skill 58)", "a 6-point stretch — try it on a soft
  day", "big stretch (+14) — ski Ellie's first".

### 7.6 Milestones

`Milestone { id, title, symbol, predicate: (UserData, TrailCatalog) -> Progress }` where
`Progress = .locked(fraction: Double?) | .unlocked(Date)`. Registry (V1):

| id                    | Title                        | Predicate                                                   |
|-----------------------|------------------------------|-------------------------------------------------------------|
| `first.green/blue/black/doubleBlack` | First Green / Blue / Black / Double Black | ≥1 done with effective band |
| `all.greens` … `all.doubleBlacks` | All Greens / Blues / Blacks / Double Blacks | every catalog trail of that band done (fraction shown) |
| `trail.gunbarrel`     | Gunbarrel                    | `t-gunbarrel` done                                          |
| `trail.theFace`       | The Face                     | `t-the-face` done                                           |
| `area.mottCanyon`     | Mott Canyon                  | ≥1 `mottCanyon` trail done                                  |
| `area.mottComplete`   | Mott Canyon, every chute     | all `mottCanyon` done                                       |
| `area.killebrew`      | Killebrew Canyon             | ≥1 `killebrewCanyon` trail done                             |
| `area.bothStates`     | Two States, One Day          | a ski day with runs in CA and NV                            |
| `first.glade`         | Into the Trees               | ≥1 gladed trail done                                        |
| `first.moguls`        | Bump Run                     | ≥1 `moguls` trail done                                      |
| `count.25/50/100`     | 25 / 50 / 100 Trails         | done count                                                  |
| `days.10`             | Ten Days on Snow             | ≥10 ski days                                                |
| `half`                | Halfway                      | done ≥ 50% of catalog                                       |

Unlock dates are stored in `profile.unlockedMilestones` so they survive catalog/engine changes.

### 7.7 Persistence: one JSON document

Path: `~/Library/Application Support/HeavenlyTracker/userdata.json`
(`FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask)` + bundle id folder).

- **Atomic writes**: encode to `Data` (ISO-8601 dates, sorted keys, pretty-printed), write to
  `userdata.json.tmp` in the same directory, then `FileManager.replaceItemAt` (or
  `Data.write(options: .atomic)`). Keep `userdata.backup.json` = previous version on each successful
  save (cheap, one generation) so a corrupt write is recoverable.
- **Save policy**: debounce 500 ms after any mutation; flush synchronously on
  `applicationShouldTerminate`, on window close and on `Cmd+Shift+E` export. A `*` in the window
  title is **not** shown (autosave model, like Notes).
- **Load**: if the file is missing → fresh `UserData`. If decoding fails → try the backup, else
  rename the bad file to `userdata.corrupt-<timestamp>.json`, start fresh, and show an alert with
  "Reveal in Finder".
- **Versioning**: `schemaVersion` integer. `Migrations.run(json: [String: Any], from: Int) -> [String: Any]`
  applies `v1→v2, v2→v3…` as dictionary transforms before decoding. Files with a *newer* version than
  the app refuse to load (alert; never overwrite them).
- **Pruning**: `trailStates` entries equal to the default are dropped on save; log is never pruned.

Why a JSON document rather than SwiftData:
1. **Size**: ≤ 165 trail states + a few thousand log entries; whole-document load/save is
   milliseconds. There is no query the app needs that is not a `filter` over an in-memory array.
2. **Build environment**: we compile with `swiftc`/`swift build` from the Command Line Tools and no
   `xcodebuild`; `@Model` macros and the SwiftData schema/migration tooling are the single most
   likely thing to break in that setup, and far harder to debug headless. Codable structs compile
   anywhere and are unit-testable without a `ModelContainer`.
3. **Parallel agents**: a Codable struct is a contract every agent can code against on day one;
   SwiftData's `@Model` classes drag SwiftUI/`ModelContext` plumbing into every screen.
4. **Export/import is free**: the document *is* the export format; it is human-readable and diffable.
5. **Undo** is simpler with value types: snapshot the struct, register undo with the snapshot.
Costs: no lazy loading (irrelevant at this size), no iCloud sync (not a V1 goal; could be added later
by syncing the file via `NSUbiquitousKeyValueStore`-triggered merge or CloudKit).

### 7.8 Export / import

- **Export Data… (`Cmd+Shift+E`)**: `NSSavePanel`, default name `HeavenlyTracker-2026-11-01.json`;
  writes the same document plus `"exportedAt"`. Also **Export Log as CSV** *(later)*:
  `date,trail,rating,conditions,multiplier,confidence,notes`.
- **Import Data… (`Cmd+Shift+I`)**: `NSOpenPanel` → decode (with migrations) → summary sheet
  ("Found 53 done trails, 212 runs, 9 bucket items from Jan 2026") with two buttons:
  **Replace** (backs up current to `userdata.pre-import-<ts>.json`, then overwrites) and
  **Merge**: per trail, status = max(done > bucket > notDone), earliest `firstDoneDate`, sum
  `timesSkied` is *not* summed (recomputed from the merged log), override = imported if local is nil,
  notes concatenated with a separator if different; log = union by `id`; bucketOrder = local then
  new ids appended; milestones = earliest dates. Both are undoable as a single step.

---

## 8. Visual design

### 8.1 The 1–100 color ramp

Continuous, piecewise-linear in sRGB between these stops (interpolate between neighbors; implement
as `Ramp.color(for rating: Int) -> RGBA`, unit-tested at the stops):

| Rating | Hex       | Name            |
|-------:|-----------|-----------------|
| 1      | `#3BD07C` | spring green    |
| 15     | `#2EC4A0` | teal            |
| 25     | `#2E9BF0` | sky blue        |
| 40     | `#2F6BE6` | blue            |
| 50     | `#5A4FD8` | indigo          |
| 62     | `#7E3FC9` | violet          |
| 75     | `#B8336A` | magenta-rose    |
| 88     | `#C8102E` | red             |
| 100    | `#4A0010` | maroon-black    |

Design intent: hue moves monotonically green → blue → purple → red → near-black, so "warmer and
darker = harder" reads instantly, and every stop is distinguishable against satellite imagery
(greens/browns/white) once cased in white. Done trails use the same hue desaturated so the structure
of what you've skied still reads as difficulty. Lightness drops toward 100 on purpose: the hardest
chutes look like black diamonds.

Band chips (used for symbols and section headers, not for lines): green `#34C759`, blue
`#0A84FF`, black `.primary` (so the diamond is black in light mode and white in dark mode),
double-black `.primary` ×2 with a `#C8102E` 1 pt outline.

Status colors: done `#34C759` (system green), bucket `#FFD60A` (system yellow), toast background
`.regularMaterial`. Readiness chips: ready `#34C759`, stretch `#FF9F0A`, big stretch `#FF453A`,
below you `#8E8E93`.

### 8.2 Typography and components

- System font throughout (SF Pro); numerals `.monospacedDigit()` in tables, stats and pills.
- Rating pill: `Text("\(rating)")` `.font(.system(.title2, design: .rounded, weight: .bold))`
  in a capsule filled with `ramp(rating)`, white text (`#4A0010` end still passes contrast; the
  `#3BD07C` end uses `#0B2E1A` text — pick text color by relative luminance > 0.5).
- Band symbols: SF Symbols `circle.fill`, `square.fill`, `diamond.fill`; double black = two
  `diamond.fill` with `-2` pt spacing (define `BandSymbol` view).
- Stats grid: `LabeledContent` in a 2-column `Grid`.
- Charts: Swift Charts only; chart colors come from `Ramp` so charts and map agree.
- Toasts: top-right capsule, `.regularMaterial`, 4 s, slide+fade; at most one visible, newest wins.
- Materials/vibrancy: sidebar `.sidebar` material (default), inspector default, map overlays
  `.ultraThinMaterial` cards with 10 pt radius.

### 8.3 Dark mode

Everything UI uses semantic system colors, so dark mode is automatic. Data colors (ramp, band
chips, status) are **identical** in both modes; only casings/halos flip (white on satellite in both
modes; `#1C1C1E` on the Outline base in light mode, white on Outline in dark mode where the Outline
background becomes `#1C1C1E`). Chart gridlines use `.quaternary`.

### 8.4 App icon concept

macOS squircle. Background: vertical gradient from Tahoe sky `#9BD3FF` (top) to lake blue
`#1B4F8A` (bottom). Foreground: a two-peak white mountain silhouette (left peak CA, right peak
NV, the right one slightly taller) with a single bold trail line descending left-to-right across
both, drawn in the 1→100 ramp gradient. A green check badge (`#34C759`, white `checkmark`) sits at
the bottom-right of the trail line. No text. Generate as SVG → PNG set (16…1024) → `.icns` via
`iconutil` (available in CLT) in `Resources/AppIcon.icns`.

---

## 9. Scope and build plan

### 9.1 V1 must-haves (buildable in a few hours by parallel agents)

- [ ] **P0 Catalog**: `trails.json` with merged named trails, elevations, length/vert/grades,
      profile samples, area/subArea, lifts, boundary, precomputed `RatingBreakdown`.
- [ ] **P0 Core**: `HeavenlyCore` models (§7), `Ramp`, `TrailFilter`, `TrailStyleBuilder`,
      `DefaultProgressionEngine`, milestones, JSON persistence with atomic save/load + migrations
      scaffold, undo.
- [ ] **P0 Shell**: `NavigationSplitView`, 5 sections, toolbar, search, Inspector, keyboard
      shortcuts, menu commands, Settings (General + Data), onboarding slider.
- [ ] **P0 Map**: `MapEngine` protocol + one working engine (MapKit first: `MKMapView` with
      `.hybridFlyover`/elevated `MKMapConfiguration`, `MKPolyline` overlays with custom renderer,
      hit-testing), 4 camera presets, selection → Inspector, styling per §2.2, badges via overlay,
      legend, toast, mark-done animation (overlay-level is acceptable if engine can't animate).
- [ ] **P0 Trails**: sortable `Table`, filter, group-by, multi-select bulk actions, context menu.
- [ ] **P0 Inspector**: header, status segmented control, Log Run, stats grid, elevation profile
      chart, rating breakdown, override popover, notes, history.
- [ ] **P0 Bucket List**: reorderable list, ring, suggested next, crossed-off section, add popover.
- [ ] **P0 Log**: ski-day grouped list, Log Run sheet, edit/delete, day meta.
- [ ] **P0 Progress**: 4 stat tiles, skill line chart, histogram, ready-for list, milestones grid.
- [ ] **P0 Packaging**: `swift build` SwiftPM executable + script that assembles
      `HeavenlyTracker.app` (Info.plist, icon, bundled `trails.json`), launches without Xcode.
- [ ] **P1 Export/Import** (replace + merge).

Acceptance for V1: launch → onboarding → Map shows 3D terrain with 126 colored trails → click
Gunbarrel → Inspector → Mark Done → animation + toast + Bucket/Progress update → quit → relaunch →
state persists.

### 9.2 Later

Full-page trail detail with photos; SceneKit/MapLibre engines and engine picker; CSV export;
Quick Look preview (`Space`); iCloud sync; season comparison; share card image of a ski day;
OSM re-fetch from the app; snow-report integration; trail "variants" (skier's left/right lines);
Widgets.

### 9.3 Suggested work packages (parallel, with contracts)

| Package | Owner agent      | Produces                                                   | Depends on                |
|---------|------------------|------------------------------------------------------------|---------------------------|
| A Data  | pipeline         | `Resources/trails.json`, `data/overrides/trail_overrides.json`, `tools/build_trails.*` | raw OSM, elevation APIs |
| B Rating| rating engine    | `HeavenlyCore/Rating/*` + `RatingBreakdown` for every trail (called by A) | A's features |
| C Core  | core/persistence | `HeavenlyCore` models, `AppStore`, `Persistence`, `Ramp`, `TrailStyleBuilder`, progression, milestones, tests | this spec |
| D Map   | map engine       | `MapEngine.swift` (from §2.7 verbatim), `MapKitEngine`, `MapScreen` overlays | C (ids/geometry types) |
| E Screens | UI            | Shell, Trails, Inspector, Bucket, Log, Progress, Settings, onboarding | C |
| F Build | packaging        | `Package.swift`, `scripts/build_app.sh`, icon, Info.plist  | — |

Shared file layout (SwiftPM):

```
HeavenlyTracker/
  Package.swift                      # targets: HeavenlyCore (lib), HeavenlyTracker (exe)
  Sources/HeavenlyCore/{Models,Rating,Progression,Persistence,Style,MapEngine.swift}
  Sources/HeavenlyTracker/{App,Shell,Map,Trails,Inspector,Bucket,Log,Progress,Settings}
  Sources/HeavenlyTracker/Resources/trails.json
  Tests/HeavenlyCoreTests/
  tools/, data/raw/, data/overrides/, docs/
```

---

## Appendix A — Facts from the raw data (verified 2026-11-01 with jq)

- 165 `piste:type=downhill` ways; 131 named → **126 unique trail names** (the orchestrator brief said 127; `jq unique` on `tags.name` gives 126); 34 unnamed.
- `piste:difficulty`: easy 17, intermediate 75, advanced 40, expert 29, none 4.
- `piste:grooming`: classic 77, mogul 20, backcountry 4, none 64. `gladed=yes` on 52.
- Named lifts (21): Aerial Tramway (cable_car), Heavenly Gondola (gondola), chair_lifts Big Easy,
  Boulder, Canyon Express, Comet Express, Dipper Express, First Ride, Galaxy, Groove, Gunbarrel
  Express, Mott Canyon, North Bowl Express, Olympic Express, Patsy's, Powderbowl Express, Sky
  Express, Stagecoach Express, Tamarack Express, World Cup; magic_carpet Tubing Hill; rope_tow
  Pioneer. 13 `station` ways (mostly unnamed) — ignore.
- Mott Canyon chair: bottom 38.9328,-119.8882 (east) → top 38.9321,-119.8970 (west).
- CA/NV split by the oblique line (slope 1.342°lon/°lat) gives 43 CA / 83 NV named trails; borderline names listed in §7.1.
- Boundary relation 12152028, 6 members, geometry included.
- Multi-way names: Canyonland, Hogsback, Pinnacles, Ski Ways Glades, Tamarack Return (2 ways each).

## Appendix B — Glossary

- **Rating**: engine-computed 1–100 (`trail.rating.total`). **Effective rating**: user override if
  set, else computed. Every visual and calculation uses the effective rating.
- **Band**: green/blue/black/double-black derived from effective rating (25/50/75 cuts).
- **OSM color**: the resort/OSM `piste:difficulty`, shown for comparison only.
- **Crossed off**: a trail that was on the bucket list and is now done.
- **Ski day**: all log entries on one local calendar day.
- **Skill**: progression engine's estimate (1–100) of what the user skis comfortably.
