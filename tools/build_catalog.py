#!/usr/bin/env python3
"""Build Sources/SkiLo/Resources/trails.json (DESIGN.md section 4) from data/*.json.

Run:  python3 -I tools/build_catalog.py [--out PATH]
Stdlib only. Exits 1 on any validation failure.
"""
import argparse
import datetime
import json
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
DEFAULT_OUT = os.path.join(ROOT, "Sources", "SkiLo", "Resources", "trails.json")

RATING_ENGINE_VERSION = "rating-v1-2026-11-01"

# --- RATING_METHOD Appendix B reference implementation (verbatim) -------------------------
BASE = [(0,0),(10,2),(15,5),(20,10),(25,16),(30,24),(35,32),(40,40),(45,47),(50,53),(55,58),(60,63),(65,67),(70,71),(80,77),(90,81),(100,84),(120,88)]
FLOOR = {"easy":0, "intermediate":15, "advanced":45, "expert":62}
CEIL  = {"easy":30, "intermediate":58, "advanced":85, "expert":100}
def pl(x, pts):
    if x <= pts[0][0]: return pts[0][1]
    if x >= pts[-1][0]: return pts[-1][1]
    for (x0,y0),(x1,y1) in zip(pts[:-1], pts[1:]):
        if x0 <= x <= x1: return y0 + (y1-y0)*(x-x0)/(x1-x0)
def ramp(x, a, b): return max(0.0, min(1.0, (x-a)/(b-a)))
def rate(t, m):
    S, M, V = t["sustained_grade_pct"], t["max_grade_pct"], t["vertical_drop_m"]
    d, grooming, gladed = t.get("osm_difficulty"), t.get("grooming"), bool(t.get("gladed"))
    trees = m.get("trees", gladed); moguls = m.get("moguls_typical", grooming == "mogul"); traverse = m.get("traverse", False)
    base = pl(S, BASE)
    max_bonus = 0.35 * max(0.0, min(12.0, M - S)) * ramp(S, 20, 30)
    fatigue = 0.0 if traverse else min(10.0, 2.0 * V / 100.0) * ramp(S, 10, 30)
    terrain = 0.0
    if moguls: terrain += 5 + 0.10 * S
    if trees: terrain += 8
    elif not moguls:
        if grooming == "backcountry" or (grooming is None and d == "expert"): terrain += 4
        elif grooming is None and d == "advanced": terrain += 2
    hz = 0.0
    if m.get("chute"): hz += 6
    elif m.get("narrow") or traverse: hz += 3
    if m.get("gated"): hz += 4
    if m.get("hike_to"): hz += 3
    hz += 10 * float(m.get("cliff_exposure", 0.0))
    raw = base + max_bonus + fatigue + terrain + hz
    f, c = FLOOR.get(d, 0), CEIL.get(d, 100)
    if raw < f: raw = (raw + f) / 2
    if raw > c: raw = (raw + c) / 2
    if m.get("gated"): raw = max(raw, 60.0)
    soft = raw if raw <= 85 else 85 + 15 * (1 - math.exp(-(raw - 85) / 15))
    return max(1, min(100, int(round(soft))))
# -------------------------------------------------------------------------------------------

errors = []
def fail(msg): errors.append(msg)

def load(*parts):
    with open(os.path.join(DATA, *parts), encoding="utf-8") as f:
        return json.load(f)

def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def hav(a, b):
    r = 6371008.8
    la1, la2 = math.radians(a[1]), math.radians(b[1])
    dla, dlo = la2 - la1, math.radians(b[0] - a[0])
    h = math.sin(dla/2)**2 + math.cos(la1)*math.cos(la2)*math.sin(dlo/2)**2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))

def midpoint(coords):
    total = sum(hav(coords[i], coords[i+1]) for i in range(len(coords)-1))
    half, acc = total / 2, 0.0
    for i in range(len(coords)-1):
        d = hav(coords[i], coords[i+1])
        if d > 0 and acc + d >= half:
            f = (half - acc) / d
            return [coords[i][j] + (coords[i+1][j] - coords[i][j]) * f for j in range(3)]
        acc += d
    return list(coords[-1])

def grooming_map(g):
    if isinstance(g, list):
        g = next((x for x in g if x), None)
    return {"classic": "groomed", "mogul": "moguls", "backcountry": "backcountry"}.get(g, "unknown")

def profile_with_grades(p):
    out = []
    n = len(p)
    for i, (d, e) in enumerate(p):
        if n == 1:
            g = 0.0
        elif i < n - 1:
            dd = p[i+1][0] - d
            g = (e - p[i+1][1]) / dd * 100 if dd else 0.0
        else:
            g = out[-1][2]
        out.append([d, e, g])
    return out

AREA = {"California": "CA", "Nevada": "NV"}
STAT_KEYS = [("length_m", "lengthM"), ("vertical_drop_m", "verticalDropM"), ("top_elev_m", "topElevM"),
             ("bottom_elev_m", "bottomElevM"), ("avg_grade_pct", "avgGradePct"), ("max_grade_pct", "maxGradePct"),
             ("sustained_grade_pct", "sustainedGradePct"), ("p90_grade_pct", "p90GradePct"),
             ("terrain_slope_pct_p90", "terrainSlopePctP90"), ("aspect_deg", "aspectDeg"),
             ("max_segment_length_m", "maxSegmentLengthM")]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    src = load("trails.json")
    lifts_src = load("lifts.json")
    boundary_src = load("boundary.json")
    mods = load("curated_modifiers.json")
    ov = load("overrides", "trail_overrides.json")
    anchors = load("calibration_anchors.json")

    pod_of_lift = {lift: pod for pod, lifts in ov["liftPods"].items() for lift in lifts}

    trails, connectors = [], []
    bounds_pts = []
    named = [t for t in src["trails"] if not t.get("unnamed")]
    unnamed = [t for t in src["trails"] if t.get("unnamed")]

    for t in named:
        name = t["name"]
        tid = "t-" + slug(name)
        area = ov["areaByName"].get(name) or AREA.get(t.get("area"))
        if area not in ("CA", "NV"):
            fail(f"{name}: bad area {t.get('area')!r}")
        nl = t.get("nearest_lift") or {}
        lift_name = ov["liftNameByName"].get(name, nl.get("name"))
        sub = ov["subAreaByName"].get(name) or pod_of_lift.get(nl.get("name")) or "other"
        grooming_raw = t.get("grooming")
        if isinstance(grooming_raw, list):
            grooming_raw = next((x for x in grooming_raw if x), None)
        diff = t.get("osm_difficulty")
        segs = t["segments"]
        geometry = [s["coords"] for s in segs]
        for g in geometry:
            bounds_pts.extend(g)
        longest = max(segs, key=lambda s: s["stats"]["length_m"])
        stats = {new: t["stats"][old] for old, new in STAT_KEYS}
        stats["segmentsRelation"] = t["segments_relation"]
        m = mods.get(name, {})
        rated = {"sustained_grade_pct": t["stats"]["sustained_grade_pct"], "max_grade_pct": t["stats"]["max_grade_pct"],
                 "vertical_drop_m": t["stats"]["vertical_drop_m"], "osm_difficulty": diff,
                 "grooming": grooming_raw, "gladed": t.get("gladed")}
        trails.append({
            "id": tid, "name": name, "pipelineID": t["id"], "osmWayIDs": t["osm_way_ids"],
            "area": area, "areaConfidence": t.get("area_confidence", "low"), "subArea": sub,
            "liftName": lift_name, "liftAtBottomName": (t.get("lift_at_bottom") or {}).get("name"),
            "osmDifficulty": diff or "unknown", "grooming": grooming_map(t.get("grooming")),
            "gladed": bool(t.get("gladed")), "oneway": t.get("oneway") == "yes",
            "geometry": geometry, "midpoint": midpoint(longest["coords"]),
            "top": t["top"], "bottom": t["bottom"], "stats": stats,
            "profile": profile_with_grades(t["profile"]),
            "modifiers": m, "expectedRating": rate(rated, m),
        })

    id_by_name = {t["name"]: t["id"] for t in trails}
    for u in unnamed:
        pl_ = u["segments"][0]["coords"] if len(u["segments"]) == 1 else [c for s in u["segments"] for c in s["coords"]]
        bounds_pts.extend(pl_)
        connectors.append({
            "id": "u-" + str(u["osm_way_ids"][0]), "osmWayID": u["osm_way_ids"][0], "name": u["name"],
            "nearestTrail": id_by_name.get(u.get("nearest_named_trail")),
            "osmDifficulty": u.get("osm_difficulty") or "unknown", "polyline": pl_,
        })

    lifts = []
    for l in lifts_src["lifts"]:
        bounds_pts.extend(l["polyline"])
        lifts.append({
            "id": "l-" + str(l["osm_way_id"]), "osmWayID": l["osm_way_id"], "name": l["name"], "kind": l["type"],
            "area": AREA.get(l.get("side")), "polyline": l["polyline"],
            "bottomElevM": l["bottom_elev_m"], "topElevM": l["top_elev_m"],
            "verticalM": l["vertical_m"], "lengthM": l["length_m"],
        })

    ring = boundary_src["geometry"]["coordinates"][0]
    lons = [p[0] for p in bounds_pts]; lats = [p[1] for p in bounds_pts]
    bounds = {"minLat": min(lats), "minLon": min(lons), "maxLat": max(lats), "maxLon": max(lons)}

    catalog = {
        "schemaVersion": 1, "resort": "Heavenly Mountain Resort",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "osm": "OpenStreetMap via Overpass API (data/raw/heavenly_osm.json)",
            "license": "ODbL 1.0 (c) OpenStreetMap contributors",
            "osmTimestamp": src["osm_timestamp"],
            "elevation": "AWS Terrain Tiles (Mapzen terrarium) z14; see data/dem/dem_meta.json",
            "pipeline": "tools/build_trails.py + tools/build_catalog.py",
            "modifiersVersion": "v1-2026-11-01",
        },
        "ratingEngineVersion": RATING_ENGINE_VERSION, "bounds": bounds,
        "trails": trails, "connectors": connectors, "lifts": lifts, "boundary": [ring],
    }

    # ---- validation -------------------------------------------------------------------
    if len(trails) != 126: fail(f"expected 126 trails, got {len(trails)}")
    if len(connectors) != 34: fail(f"expected 34 connectors, got {len(connectors)}")
    if len(lifts) != 23: fail(f"expected 23 lifts, got {len(lifts)}")
    ids = [t["id"] for t in trails]
    if len(set(ids)) != len(ids): fail("duplicate trail ids")
    for i in ids:
        if not re.fullmatch(r"t-[a-z0-9-]+", i): fail(f"bad id {i}")
    for l in lifts:
        if l["area"] is None: fail(f"lift {l['name']}: no area")
    matched = sum(1 for t in trails if t["modifiers"])
    if matched != len(mods) or matched != 90: fail(f"curated modifiers matched {matched} of {len(mods)} (expected 90)")
    def cnt(s): return sum(1 for t in trails if t["subArea"] == s)
    if cnt("mottCanyon") != 14: fail(f"mottCanyon {cnt('mottCanyon')} != 14")
    if cnt("killebrewCanyon") != 11: fail(f"killebrewCanyon {cnt('killebrewCanyon')} != 11")
    for t in trails:
        for g in t["geometry"]:
            if len(g) < 2: fail(f"{t['id']}: polyline < 2 points")
            for c in g:
                if len(c) != 3: fail(f"{t['id']}: coordinate without ele")
    for p in bounds_pts:
        if not (bounds["minLon"] <= p[0] <= bounds["maxLon"] and bounds["minLat"] <= p[1] <= bounds["maxLat"]):
            fail("coordinate outside bounds")
    by_name = {t["name"]: t for t in trails}
    n_anch = 0
    anchor_rows = []
    for a in anchors["trails"]:
        if a["name"] not in by_name: fail(f"anchor {a['name']} missing"); continue
        if a.get("target") is None: continue
        n_anch += 1
        r = by_name[a["name"]]["expectedRating"]
        ok = abs(r - a["target"]) <= a["tol"]
        anchor_rows.append((a["name"], a["target"], a["tol"], r, ok))
        if not ok: fail(f"anchor {a['name']}: {r} vs target {a['target']} +/- {a['tol']}")
    if n_anch != 29: fail(f"expected 29 anchors, got {n_anch}")

    # ---- output -----------------------------------------------------------------------
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(catalog, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")

    rs = sorted(t["expectedRating"] for t in trails)
    bands = [("<25", lambda r: r < 25), ("25-49", lambda r: 25 <= r < 50), ("50-74", lambda r: 50 <= r < 75), (">=75", lambda r: r >= 75)]
    print(f"wrote {args.out} ({os.path.getsize(args.out)/1e6:.2f} MB)")
    print(f"trails {len(trails)}  connectors {len(connectors)}  lifts {len(lifts)}  boundary pts {len(ring)}")
    print(f"rating min/median/max: {rs[0]} / {rs[len(rs)//2]} / {rs[-1]}")
    six = [(1,20),(21,40),(41,55),(56,70),(71,85),(86,100)]
    print("six-band histogram:", [sum(1 for r in rs if lo <= r <= hi) for lo, hi in six])
    print("four-band histogram:", {n: sum(1 for r in rs if f(r)) for n, f in bands})
    print(f"anchors: {sum(1 for r in anchor_rows if r[4])}/{len(anchor_rows)} within tolerance")
    if errors:
        print("VALIDATION FAILED:", file=sys.stderr)
        for e in errors: print("  " + e, file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
