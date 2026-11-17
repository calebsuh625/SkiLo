# HeavenlyTracker V1 acceptance (WP6, 2026-11-02)

Assembled release app: `build/HeavenlyTracker.app` (ad-hoc signed, `codesign --verify` valid).
Screenshots: `/private/tmp/claude-501/-Users-calebsuh/810bede8-95e3-4752-88a3-c504cfe6ddb2/scratchpad/acc/` (each viewed; descriptions below are of what was actually seen).

## Commands and results
- `swift build` (debug): Build complete, 0 errors. `tools/build_app.sh` (release + sign): built.
- `tools/build_app.sh sync-data`: 126 trails, 34 connectors, 23 lifts, anchors 29/29 within tolerance.
- `tools/run_tests.sh`: `Test run with 120 tests in 12 suites passed after 0.873 seconds.`
- `tools/build_app.sh verify`: screenshot written, Bundle.appResources resolves, trails.json 467713 bytes.
- LaunchServices: `open build/HeavenlyTracker.app`; `lsappinfo` listed bundleID com.calebsuh.HeavenlyTracker pid 35807 (Foreground); `pkill -TERM` ended it. PASS.
- `grep -rn "pending" Sources/ | grep -i WP`: empty. PASS (no stubs left).
- Memory/time (`/usr/bin/time -l`, shot c California+select): 12.76 s wall (10 s of it is the capture delay), max RSS 952 MB (target <= 1.1 GB met in this run). Other runs: overview 246 MB, mark-done 626 MB. WP3 reported 3-6 GB in earlier runs, so RSS is variable; not guaranteed.

## Walk-through (assembled app, fresh HT_USERDATA_DIR)
| Step | Result | Screenshot | What was seen |
|---|---|---|---|
| a onboarding | PASS (needed `HT_SHOW_ONBOARDING=1`, see edits) | a_onboarding.png | "Welcome" sheet over dimmed map: skill 30 / Blue pill, ramp slider, anchors Maggie's 11, Olympic Downhill 37, Ellie's 64, Gunbarrel 81, Snake Eyes 95 (no overlap), backfill checkboxes (30 greens, 29 blues), Skip/Start. Sidebar skill card 30 est. |
| b overview | PASS | b_overview.png | Satellite with relief, 126 ramp-coloured trails with casing, white dashed lifts incl. the long gondola, legend top-left, OSM credit, chips Overview/CA/NV/Mott-Killebrew, Apple Maps logo + Legal bottom-left. Pitch looks fairly steep-down; relief is visible but subtle. |
| c select | PASS | c_select.png | California close 3D view, Gunbarrel thick red line with label; inspector: 81 pill, Double Black, status segmented control (Not done selected), stats, elevation chart, "Why 81?" breakdown (sustained grade +63 etc., Computed 81), Override button, "Not skied yet". |
| d mark done | PARTIAL | d_markdone.png, d2/d3_toast.png | Gunbarrel drawn pale pink/desaturated with green check badge, Done selected, history "Skied 1x - first Nov 2, 2026", sidebar 1/126 done. `userdata.json` contains `"t-gunbarrel"` with `"status" : "done"` (verified). The toast with Undo was NOT visible in any assembled-app capture (delays 4 s and 16 s, with and without bucket); WP4 saw it in its own earlier shot. Toast unverified in the assembled app. |
| e relaunch bucket | PASS | e_bucket.png | Same userdata dir: sidebar "1/126 done" (Gunbarrel persisted), Bucket List badge 1, bucket shows The Face 69, ring 0/1, suggested next The Face, drag handle, Done button. |
| f trails | PASS (Gunbarrel row not in the visible slice) | f_trails.png | Table sorted by Name ascending, columns St/Name/Area/Rating pill/Band/OSM/Length/Vert/Avg/Max, header "126 trails - 1 done - 1 bucketed". Columns clip at right with the inspector open. Persisted done state evidenced by header and i_outline.png. |
| g progress | PASS | g_progress.png | Tiles Skill 30 Blue, Done 1/126 (CA 1/50, NV 0/76), Days on snow 0, streak 0; skill chart with a single starting-estimate point; histogram with one done bar in 81-90; "Ready for you" list with Add all to bucket. Below-fold content not seen. |
| h log | PASS | h_log.png | Empty state "No runs logged yet" with Log Run button. |
| i outline | PASS | i_outline.png | Flat dark muted map with creek/street labels, all trails coloured, lifts dashed, Gunbarrel green check badge and The Face star badge both visible, legend, chips, Apple logo. |
| click | PASS | (log only) | `HT_CLICK expected t-gunbarrel -> selection t-gunbarrel => PASS`. |

## UX_SPEC 9.1 P0 checklist
- [x] Catalog: 126 trails, rating min/median/max 5/53/97, anchors 29/29. Tests green.
- [x] Core: models, ramp, filter, style, progression, milestones, persistence (atomic, migration, undo), 120 tests.
- [x] Shell: split view, 5 sections, search, inspector, onboarding, Settings window (WP4 shot). Keyboard shortcuts/menu enablement NOT verified.
- [x] Map: MapKit engine, 3D terrain, presets, selection->inspector, styling, badges, legend, click picking. Hover, offline fallback, animation frames NOT verified.
- [x] Trails table (sortable): seen. Group-by, multi-select bulk actions, context menu NOT verified.
- [x] Inspector: header, status control, Log Run, stats, chart, breakdown, override button, history seen; override popover and notes editing NOT verified.
- [x] Bucket: list, ring, suggested next seen; Crossed Off section, reorder, add popover NOT verified in assembled app.
- [~] Log: empty state seen here; populated log seen by WP5 on a fixture; LogRunSheet/edit NOT verified.
- [x] Progress: tiles, chart, histogram, ready-for seen; milestones grid below fold not seen.
- [x] Packaging: .app builds, signs, launches via LaunchServices and headless.
- [x] Export/import: tests only, panels not exercised.
- V1 acceptance flow: onboarding -> map -> click Gunbarrel (synthetic) -> inspector -> Done (via hook) -> badge -> relaunch persists: PASS except the toast.

## Known gaps (updated after the finishing pass)
- FIXED: toast now bottom-center over the map, 3 s auto-dismiss, no longer covers the inspector. Seen in screenshot ("Gunbarrel crossed off / Undo / Log run...") ~2 s after HT_MARK_DONE.
- FIXED: sidebar bucket badge counts only ids present in the catalog (`bucketBadgeCount`, test added).
- Memory: engine already diffs styles (only changed trails restyled) and caches renderers. Only change made: map line-width scale quantised to 0.2 steps so zooming redraws all lines less often. Same scenario max RSS: before 472 MB, after 458/498/480 MB (no measurable change). The 3-6 GB reports were NOT reproduced; likely MapKit's own 3D terrain/imagery tile cache at close pitch, not fixed.
- Tests: 124 tests in 13 suites pass. New tests cover log run (Log, timesSkied, skill history), moveBucket, export/import round trip (dates are stored to whole seconds, so sub-second precision is lost by design).
- Installed to ~/Applications/HeavenlyTracker.app, codesign valid, launches via `open` (lsappinfo confirmed). Real data folder is ~/Library/Application Support/HeavenlyTracker (created on first change; not present yet, so no test data written there).
- Still unverified (need real clicks): export/import file panels, LogRunSheet UI, drag-reorder in Bucket UI, keyboard shortcuts, hover, offline fallback, override popover, notes editing.
- Tight rating anchors (Milky Way Bowl, North Bowl) pass with zero slack. No AppIcon.
