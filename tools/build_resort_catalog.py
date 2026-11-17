#!/usr/bin/env python3
"""Build Sources/SkiLo/Resources/trails-<resort>.json for resorts beyond Heavenly.

Run after `tools/build_trails.py --resort=<id>`:
    python3 -I tools/build_resort_catalog.py kirkwood
    python3 -I tools/build_resort_catalog.py mtrose

Same catalog format as trails.json (Heavenly), with three differences:
  * ids carry a resort prefix (t-kw-…, l-kw-…, u-kw-…) so they never collide with Heavenly's;
  * area is "MAIN" and subArea "other" (Heavenly's CA/NV sides and pods don't apply);
  * no curated modifiers or calibration anchors yet: ratings come from OSM + terrain alone.
Stdlib only (rating code is shared with build_catalog.py).
"""
import datetime
import importlib.util
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("build_catalog", os.path.join(ROOT, "tools", "build_catalog.py"))
bc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bc)

RESORTS = {
    "kirkwood": {"name": "Kirkwood Mountain Resort", "prefix": "kw"},
    "mtrose": {"name": "Mt. Rose Ski Tahoe", "prefix": "mr"},
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in RESORTS:
        sys.exit(f"usage: build_resort_catalog.py {{{','.join(RESORTS)}}}")
    rid = sys.argv[1]
    info = RESORTS[rid]
    px = info["prefix"]
    data = os.path.join(ROOT, "data", rid)
    src = json.load(open(os.path.join(data, "trails.json"), encoding="utf-8"))
    lifts_src = json.load(open(os.path.join(data, "lifts.json"), encoding="utf-8"))
    boundary_path = os.path.join(data, "boundary.json")
    boundary = []
    if os.path.exists(boundary_path):
        boundary = [json.load(open(boundary_path, encoding="utf-8"))["geometry"]["coordinates"][0]]

    errors = []
    trails, connectors, bounds_pts = [], [], []
    named = [t for t in src["trails"] if not t.get("unnamed") and not t["name"].startswith("Unnamed")]
    unnamed = [t for t in src["trails"] if t.get("unnamed") or t["name"].startswith("Unnamed")]
    seen = {}
    for t in named:
        name = t["name"]
        base = f"t-{px}-" + bc.slug(name)
        seen[base] = seen.get(base, 0) + 1
        tid = base if seen[base] == 1 else f"{base}-{seen[base]}"
        grooming_raw = t.get("grooming")
        if isinstance(grooming_raw, list):
            grooming_raw = next((x for x in grooming_raw if x), None)
        diff = t.get("osm_difficulty")
        segs = t["segments"]
        geometry = [s["coords"] for s in segs]
        for g in geometry:
            bounds_pts.extend(g)
        longest = max(segs, key=lambda s: s["stats"]["length_m"])
        stats = {new: t["stats"][old] for old, new in bc.STAT_KEYS}
        stats["segmentsRelation"] = t["segments_relation"]
        rated = {"sustained_grade_pct": t["stats"]["sustained_grade_pct"], "max_grade_pct": t["stats"]["max_grade_pct"],
                 "vertical_drop_m": t["stats"]["vertical_drop_m"], "osm_difficulty": diff,
                 "grooming": grooming_raw, "gladed": t.get("gladed")}
        trails.append({
            "id": tid, "name": name, "pipelineID": t["id"], "osmWayIDs": t["osm_way_ids"],
            "area": "MAIN", "areaConfidence": "high", "subArea": "other",
            "liftName": (t.get("nearest_lift") or {}).get("name"),
            "liftAtBottomName": (t.get("lift_at_bottom") or {}).get("name"),
            "osmDifficulty": diff if diff in ("easy", "intermediate", "advanced", "expert") else "unknown",
            "grooming": bc.grooming_map(t.get("grooming")),
            "gladed": bool(t.get("gladed")), "oneway": t.get("oneway") == "yes",
            "geometry": geometry, "midpoint": bc.midpoint(longest["coords"]),
            "top": t["top"], "bottom": t["bottom"], "stats": stats,
            "profile": bc.profile_with_grades(t["profile"]),
            "modifiers": {}, "expectedRating": bc.rate(rated, {}),
        })

    for u in unnamed:
        pl = [c for s in u["segments"] for c in s["coords"]]
        bounds_pts.extend(pl)
        connectors.append({
            "id": f"u-{px}-" + str(u["osm_way_ids"][0]), "osmWayID": u["osm_way_ids"][0], "name": u["name"],
            "nearestTrail": None,
            "osmDifficulty": u.get("osm_difficulty") if u.get("osm_difficulty") in ("easy", "intermediate", "advanced", "expert") else "unknown",
            "polyline": pl,
        })

    kinds = {"chair_lift": "chair_lift", "gondola": "gondola", "cable_car": "cable_car", "magic_carpet": "magic_carpet",
             "rope_tow": "rope_tow", "t-bar": "rope_tow", "j-bar": "rope_tow", "platter": "rope_tow", "drag_lift": "rope_tow",
             "mixed_lift": "gondola"}
    lifts = []
    for l in lifts_src["lifts"]:
        kind = kinds.get(l["type"])
        if kind is None:
            errors.append(f"lift {l['name']}: unknown kind {l['type']}")
            continue
        bounds_pts.extend(l["polyline"])
        lifts.append({
            "id": f"l-{px}-" + str(l["osm_way_id"]), "osmWayID": l["osm_way_id"],
            "name": re.sub(r"\s*\(\d+\)$", "", l["name"]), "kind": kind, "area": "MAIN", "polyline": l["polyline"],
            "bottomElevM": l["bottom_elev_m"], "topElevM": l["top_elev_m"],
            "verticalM": l["vertical_m"], "lengthM": l["length_m"],
        })

    lons = [p[0] for p in bounds_pts]
    lats = [p[1] for p in bounds_pts]
    catalog = {
        "schemaVersion": 1, "resort": info["name"], "resortID": rid,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "osm": f"OpenStreetMap via Overpass API (data/{rid}/raw/osm.json)",
            "license": "ODbL 1.0 (c) OpenStreetMap contributors",
            "osmTimestamp": src["osm_timestamp"],
            "elevation": f"AWS Terrain Tiles (Mapzen terrarium) z14; see data/{rid}/dem/dem_meta.json",
            "pipeline": "tools/build_trails.py --resort + tools/build_resort_catalog.py",
            "modifiersVersion": "none",
        },
        "ratingEngineVersion": bc.RATING_ENGINE_VERSION,
        "bounds": {"minLat": min(lats), "minLon": min(lons), "maxLat": max(lats), "maxLon": max(lons)},
        "trails": trails, "connectors": connectors, "lifts": lifts, "boundary": boundary,
    }

    ids = [t["id"] for t in trails]
    if len(set(ids)) != len(ids):
        errors.append("duplicate trail ids")
    for t in trails:
        for g in t["geometry"]:
            if len(g) < 2:
                errors.append(f"{t['id']}: polyline < 2 points")
    out = os.path.join(ROOT, "Sources", "SkiLo", "Resources", f"trails-{rid}.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(catalog, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    rs = sorted(t["expectedRating"] for t in trails)
    print(f"wrote {out} ({os.path.getsize(out) / 1e6:.2f} MB): {len(trails)} trails, {len(connectors)} connectors, {len(lifts)} lifts")
    print(f"rating min/median/max: {rs[0]} / {rs[len(rs) // 2]} / {rs[-1]}; bands:",
          {n: sum(1 for r in rs if lo <= r <= hi) for n, (lo, hi) in {"green": (1, 24), "blue": (25, 49), "black": (50, 74), "dbl": (75, 100)}.items()})
    lat_c, lon_c = (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2
    print(f"bounds center {lat_c:.4f}, {lon_c:.4f}")
    if errors:
        print("FAILED:", *errors, sep="\n  ", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
