#!/usr/bin/env python3
"""
build_trails.py -- Heavenly Mountain Resort data pipeline.

Turns the raw Overpass dump (data/raw/heavenly_osm.json, OpenStreetMap, ODbL)
into app-ready, elevation-enriched data:

  data/dem/heavenly_dem.png   16-bit grayscale PNG DEM  (elev_m = value * 0.1)
  data/dem/heavenly_dem.f32   same DEM as raw float32 little-endian, row-major
  data/dem/dem_meta.json      grid definition (EPSG:3857 / XYZ tile grid), encoding, verification
  data/dem/tiles/             cached terrarium tiles (re-runs are offline)
  data/trails.json            trails (ways merged by name) with per-segment + aggregate stats
  data/lifts.json             aerialways (bottom->top polylines with DEM elevations) + station footprints
  data/boundary.json          GeoJSON Feature of the landuse=winter_sports relation (stitched rings)
  data/trails_summary.csv     flat table of per-trail stats for calibration work

Elevation: AWS Terrain Tiles (Mapzen "terrarium" encoding), zoom 14, decoded as
elev = (R*256 + G + B/256) - 32768.  At 38.93 N a zoom-14 pixel is 9.5546 Web-Mercator
metres = ~7.43 ground metres, which is finer than the 15 m along-trail sampling used here.
If the tile server is unreachable and no cached tiles exist the script falls back to
open-meteo elevation on a lat/lon grid (documented in dem_meta.json["source"]).

Units: all distances/elevations in metres, grades in percent (100 * rise / run,
run = horizontal distance), angles in compass degrees (0 = N, 90 = E).

Usage:
  python3 tools/build_trails.py [--zoom 14] [--skip-verify] [--offline]
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import math
import random
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
RAW_PATH = ROOT / "data" / "raw" / "heavenly_osm.json"
DATA_DIR = ROOT / "data"
DEM_DIR = DATA_DIR / "dem"
TILE_DIR = DEM_DIR / "tiles"

USER_AGENT = "HeavenlyTracker/0.1 (personal ski progression tracker; python-urllib)"
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
OPEN_METEO_URL = "https://api.open-meteo.com/v1/elevation?latitude={lats}&longitude={lons}"
EPQS_URL = "https://epqs.nationalmap.gov/v1/json?x={lon}&y={lat}&units=Meters&wkid=4326"

# Requested coverage (lat 38.88..38.99, lon -119.99..-119.85). The DEM is tile-aligned
# so the actual raster bbox is slightly larger; it is written to dem_meta.json.
REQ_BBOX = {"min_lat": 38.88, "max_lat": 38.99, "min_lon": -119.99, "max_lon": -119.85}

R_EARTH_M = 6371008.8            # mean Earth radius (IUGG)
WEB_MERC_CIRC_M = 40075016.686   # 2*pi*6378137
TILE_PX = 256

SAMPLE_STEP_M = 15.0     # along-trail elevation sampling
PROFILE_STEP_M = 25.0    # elevation profile output spacing
MAX_WINDOW_M = 50.0      # window for max_grade
SUSTAINED_WINDOW_M = 150.0
ENDPOINT_SNAP_M = 10.0   # "shares an endpoint" tolerance

# Resort side ("California" vs "Nevada") for every lift, from Heavenly's own trail map.
# Trails inherit the side of their nearest lift (lift top closest to trail top).
LIFT_SIDE = {
    "Aerial Tramway": "California", "Heavenly Gondola": "California",
    "Gunbarrel Express": "California", "Powderbowl Express": "California",
    "Tamarack Express": "California", "Sky Express": "California",
    "Canyon Express": "California", "World Cup": "California", "Patsy's": "California",
    "Groove": "California", "Big Easy": "California", "First Ride": "California",
    "Pioneer": "California", "Tubing Hill": "California",
    "Dipper Express": "Nevada", "Comet Express": "Nevada", "Olympic Express": "Nevada",
    "Galaxy": "Nevada", "Mott Canyon": "Nevada", "North Bowl Express": "Nevada",
    "Stagecoach Express": "Nevada", "Boulder": "Nevada",
}

DIFF_ORDER = {"easy": 0, "intermediate": 1, "advanced": 2, "expert": 3, "freeride": 4, "extreme": 5}


# ----------------------------------------------------------------------------- geo helpers

def haversine_m(lon1, lat1, lon2, lat2):
    lon1, lat1, lon2, lat2 = (np.radians(np.asarray(v, dtype=np.float64)) for v in (lon1, lat1, lon2, lat2))
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = np.sin(dlat / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin(dlon / 2) ** 2
    return 2 * R_EARTH_M * np.arcsin(np.sqrt(np.clip(a, 0, 1)))


def bearing_deg(lon1, lat1, lon2, lat2):
    """Initial compass bearing from point 1 to point 2 (0 = N, 90 = E)."""
    p1, p2 = np.radians(np.asarray(lat1, dtype=np.float64)), np.radians(np.asarray(lat2, dtype=np.float64))
    dl = np.radians(np.asarray(lon2, dtype=np.float64) - np.asarray(lon1, dtype=np.float64))
    y = np.sin(dl) * np.cos(p2)
    x = np.cos(p1) * np.sin(p2) - np.sin(p1) * np.cos(p2) * np.cos(dl)
    return (np.degrees(np.arctan2(y, x)) + 360.0) % 360.0


def circ_mean_deg(angles_deg, weights=None):
    a = np.radians(np.asarray(angles_deg, dtype=np.float64))
    if a.size == 0:
        return None
    w = np.ones_like(a) if weights is None else np.asarray(weights, dtype=np.float64)
    s, c = float(np.sum(w * np.sin(a))), float(np.sum(w * np.cos(a)))
    if abs(s) < 1e-9 and abs(c) < 1e-9:
        return None
    return float((math.degrees(math.atan2(s, c)) + 360.0) % 360.0)


def lonlat_to_global_px(lon, lat, zoom):
    """Web-Mercator (EPSG:3857) global pixel coordinates in the XYZ tile scheme (256 px tiles)."""
    n = TILE_PX * (2 ** zoom)
    lon = np.asarray(lon, dtype=np.float64)
    lat_r = np.radians(np.asarray(lat, dtype=np.float64))
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - np.log(np.tan(lat_r) + 1.0 / np.cos(lat_r)) / math.pi) / 2.0 * n
    return x, y


def global_px_to_lonlat(x, y, zoom):
    n = TILE_PX * (2 ** zoom)
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lon, lat


def lonlat_to_3857(lon, lat):
    x = lon * WEB_MERC_CIRC_M / 360.0
    y = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)) * WEB_MERC_CIRC_M / (2 * math.pi)
    return x, y


def tile_index(lon, lat, zoom):
    x, y = lonlat_to_global_px(lon, lat, zoom)
    return int(math.floor(float(x) / TILE_PX)), int(math.floor(float(y) / TILE_PX))


def slugify(s):
    s = s.lower().replace("&", " and ")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "x"


def point_in_ring(lon, lat, ring):
    """Ray casting; ring = list of [lon, lat]."""
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat):
            x_int = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < x_int:
                inside = not inside
        j = i
    return inside


def http_get(url, timeout=30, retries=3, sleep=1.5):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            last = e
            time.sleep(sleep * (attempt + 1))
    raise RuntimeError(f"GET failed after {retries} tries: {url}: {last!r}")


# ----------------------------------------------------------------------------- DEM

class DEM:
    """Web-Mercator raster aligned to the XYZ tile grid. Pixel (col,row) covers
    global pixel [px0+col, px0+col+1) x [py0+row, py0+row+1); its value is taken to be
    centred at (px0+col+0.5, py0+row+0.5) for bilinear interpolation."""

    def __init__(self, elev, zoom, tx0, ty0, source):
        self.elev = elev.astype(np.float32)
        self.zoom = zoom
        self.tx0, self.ty0 = tx0, ty0
        self.px0, self.py0 = tx0 * TILE_PX, ty0 * TILE_PX
        self.height, self.width = elev.shape
        self.source = source
        self.px_merc_m = WEB_MERC_CIRC_M / (TILE_PX * (2 ** zoom))
        gy, gx = np.gradient(self.elev.astype(np.float64))  # per-pixel: gy south-positive, gx east-positive
        self._gx, self._gy = gx.astype(np.float32), gy.astype(np.float32)
        self.outside_count = 0

    def _bilinear(self, arr, lon, lat):
        gx, gy = lonlat_to_global_px(lon, lat, self.zoom)
        fx = gx - self.px0 - 0.5
        fy = gy - self.py0 - 0.5
        out = (fx < 0) | (fy < 0) | (fx > self.width - 1) | (fy > self.height - 1)
        self.outside_count += int(np.count_nonzero(out))
        fx = np.clip(fx, 0, self.width - 1 - 1e-9)
        fy = np.clip(fy, 0, self.height - 1 - 1e-9)
        x0 = np.floor(fx).astype(int)
        y0 = np.floor(fy).astype(int)
        x1 = np.minimum(x0 + 1, self.width - 1)
        y1 = np.minimum(y0 + 1, self.height - 1)
        tx = fx - x0
        ty = fy - y0
        a = arr.astype(np.float64)
        return (a[y0, x0] * (1 - tx) * (1 - ty) + a[y0, x1] * tx * (1 - ty)
                + a[y1, x0] * (1 - tx) * ty + a[y1, x1] * tx * ty)

    def sample(self, lon, lat):
        return self._bilinear(self.elev, lon, lat)

    def slope_aspect(self, lon, lat):
        """Terrain slope (percent) and downhill aspect (compass deg) from the DEM gradient."""
        gx = self._bilinear(self._gx, lon, lat)
        gy = self._bilinear(self._gy, lon, lat)
        ground_px = self.px_merc_m * np.cos(np.radians(np.asarray(lat, dtype=np.float64)))
        de_dx_east = gx / ground_px
        de_dy_north = -gy / ground_px
        slope_pct = np.hypot(de_dx_east, de_dy_north) * 100.0
        aspect = (np.degrees(np.arctan2(-de_dx_east, -de_dy_north)) + 360.0) % 360.0
        return slope_pct, aspect

    def bbox_lonlat(self):
        min_lon, max_lat = global_px_to_lonlat(self.px0, self.py0, self.zoom)
        max_lon, min_lat = global_px_to_lonlat(self.px0 + self.width, self.py0 + self.height, self.zoom)
        return {"min_lon": min_lon, "min_lat": min_lat, "max_lon": max_lon, "max_lat": max_lat}


def decode_terrarium(png_bytes):
    im = Image.open(io.BytesIO(png_bytes)).convert("RGB")
    a = np.asarray(im).astype(np.float64)
    return a[..., 0] * 256.0 + a[..., 1] + a[..., 2] / 256.0 - 32768.0


def fetch_terrarium_dem(zoom, offline=False):
    tx0, ty0 = tile_index(REQ_BBOX["min_lon"], REQ_BBOX["max_lat"], zoom)  # NW corner
    tx1, ty1 = tile_index(REQ_BBOX["max_lon"], REQ_BBOX["min_lat"], zoom)  # SE corner
    nx, ny = tx1 - tx0 + 1, ty1 - ty0 + 1
    print(f"[dem] zoom {zoom}: tiles x {tx0}..{tx1} ({nx}), y {ty0}..{ty1} ({ny}) = {nx*ny} tiles")
    TILE_DIR.mkdir(parents=True, exist_ok=True)
    elev = np.zeros((ny * TILE_PX, nx * TILE_PX), dtype=np.float32)
    downloaded = cached = 0
    for j, ty in enumerate(range(ty0, ty1 + 1)):
        for i, tx in enumerate(range(tx0, tx1 + 1)):
            p = TILE_DIR / f"terrarium_z{zoom}_x{tx}_y{ty}.png"
            if p.exists():
                data = p.read_bytes()
                cached += 1
            else:
                if offline:
                    raise RuntimeError(f"offline and tile missing: {p}")
                data = http_get(TILE_URL.format(z=zoom, x=tx, y=ty))
                p.write_bytes(data)
                downloaded += 1
                time.sleep(0.05)
            tile = decode_terrarium(data)
            if tile.shape != (TILE_PX, TILE_PX):
                raise RuntimeError(f"tile {p} has shape {tile.shape}")
            elev[j * TILE_PX:(j + 1) * TILE_PX, i * TILE_PX:(i + 1) * TILE_PX] = tile
    print(f"[dem] tiles: {downloaded} downloaded, {cached} from cache; raster {elev.shape[1]}x{elev.shape[0]} px; "
          f"elev {elev.min():.1f}..{elev.max():.1f} m")
    source = {
        "name": "AWS Terrain Tiles (Mapzen terrarium encoding)",
        "url_template": TILE_URL,
        "attribution": "Terrain Tiles: data from USGS 3DEP/NED, SRTM, ETOPO1 and others via Mapzen/AWS Open Data; see https://registry.opendata.aws/terrain-tiles/",
        "zoom": zoom,
        "decode": "elev_m = (R*256 + G + B/256) - 32768",
    }
    return DEM(elev, zoom, tx0, ty0, source)


def fetch_open_meteo_grid_dem(zoom):
    """Fallback: sample open-meteo elevation on the same tile-aligned grid but at 1/8 resolution,
    then upsample. Only used if the tile server is unreachable."""
    tx0, ty0 = tile_index(REQ_BBOX["min_lon"], REQ_BBOX["max_lat"], zoom)
    tx1, ty1 = tile_index(REQ_BBOX["max_lon"], REQ_BBOX["min_lat"], zoom)
    nx, ny = tx1 - tx0 + 1, ty1 - ty0 + 1
    W, H = nx * TILE_PX, ny * TILE_PX
    step = 8
    cols = np.arange(0, W, step) + 0.5
    rows = np.arange(0, H, step) + 0.5
    coarse = np.zeros((rows.size, cols.size), dtype=np.float32)
    for r_i, r in enumerate(rows):
        lons, lats = [], []
        for c in cols:
            lon, lat = global_px_to_lonlat(tx0 * TILE_PX + c, ty0 * TILE_PX + r, zoom)
            lons.append(lon)
            lats.append(lat)
        for k in range(0, len(lons), 100):
            url = OPEN_METEO_URL.format(lats=",".join(f"{v:.6f}" for v in lats[k:k + 100]),
                                        lons=",".join(f"{v:.6f}" for v in lons[k:k + 100]))
            vals = json.loads(http_get(url))["elevation"]
            coarse[r_i, k:k + len(vals)] = vals
        time.sleep(0.2)
    big = np.asarray(Image.fromarray(coarse, mode="F").resize((W, H), Image.BILINEAR), dtype=np.float32)
    source = {"name": "open-meteo elevation API (Copernicus DEM GLO-90) sampled on a grid -- FALLBACK",
              "url_template": OPEN_METEO_URL, "zoom": zoom, "grid_step_px": step}
    return DEM(big, zoom, tx0, ty0, source)


def save_dem(dem):
    DEM_DIR.mkdir(parents=True, exist_ok=True)
    scale = 0.1
    q = np.round(dem.elev / scale)
    if q.min() < 0 or q.max() > 65535:
        raise RuntimeError("elevation out of uint16 range for 0.1 m quantisation")
    u16 = q.astype(np.uint16)
    png_path = DEM_DIR / "heavenly_dem.png"
    Image.fromarray(u16).save(png_path)  # uint16 -> 16-bit grayscale PNG
    # read-back check
    back = np.asarray(Image.open(png_path))
    if back.dtype != np.uint16 or not np.array_equal(back, u16):
        raise RuntimeError("PNG16 round-trip failed")
    f32_path = DEM_DIR / "heavenly_dem.f32"
    dem.elev.astype("<f4").tofile(f32_path)
    bbox = dem.bbox_lonlat()
    minx, miny = lonlat_to_3857(bbox["min_lon"], bbox["min_lat"])
    maxx, maxy = lonlat_to_3857(bbox["max_lon"], bbox["max_lat"])
    center_lat = (bbox["min_lat"] + bbox["max_lat"]) / 2
    meta = {
        "source": dem.source,
        "crs": "EPSG:3857 (WGS84 Web Mercator); pixel grid is the XYZ/slippy tile grid at the given zoom with 256 px tiles",
        "zoom": dem.zoom,
        "tile_x_range": [dem.tx0, dem.tx0 + dem.width // TILE_PX - 1],
        "tile_y_range": [dem.ty0, dem.ty0 + dem.height // TILE_PX - 1],
        "width": dem.width,
        "height": dem.height,
        "origin": "pixel (col=0,row=0) is the NW corner of tile (tile_x_range[0], tile_y_range[0]); col increases east, row increases south",
        "pixel_size_mercator_m": dem.px_merc_m,
        "pixel_size_ground_m_at_center_lat": dem.px_merc_m * math.cos(math.radians(center_lat)),
        "pixel_size_ground_note": "ground metres per pixel = pixel_size_mercator_m * cos(lat)",
        "pixel_center_offset": 0.5,
        "lonlat_to_pixel": {
            "col": f"(lon + 180) / 360 * 2^{dem.zoom} * 256 - {dem.px0}",
            "row": f"(1 - ln(tan(lat) + sec(lat)) / pi) / 2 * 2^{dem.zoom} * 256 - {dem.py0}",
            "note": "lat in radians inside tan/sec; the value stored at integer (col,row) is centred at (col+0.5,row+0.5)",
        },
        "bbox_lonlat": bbox,
        "bbox_3857": {"min_x": minx, "min_y": miny, "max_x": maxx, "max_y": maxy},
        "requested_bbox_lonlat": REQ_BBOX,
        "min_elev_m": float(dem.elev.min()),
        "max_elev_m": float(dem.elev.max()),
        "nodata": None,
        "encoding": {
            "png": {"file": "heavenly_dem.png", "format": "16-bit grayscale PNG (uint16, single channel)",
                    "formula": "elev_m = value * 0.1", "scale": scale, "offset": 0.0},
            "f32": {"file": "heavenly_dem.f32",
                    "format": "raw float32 little-endian, row-major (height rows x width cols), no header",
                    "formula": "elev_m = value"},
        },
    }
    return meta, png_path, f32_path


def verify_dem(dem, piste_ways, n_points=12, seed=7):
    rng = random.Random(seed)
    verts = [(g["lon"], g["lat"]) for w in piste_ways for g in w["geometry"]]
    pts = rng.sample(verts, n_points)
    lons = np.array([p[0] for p in pts])
    lats = np.array([p[1] for p in pts])
    dem_vals = dem.sample(lons, lats)
    slope_pct, _ = dem.slope_aspect(lons, lats)
    result = {"n_points": n_points, "points": [], "open_meteo": None, "usgs_epqs": None}
    # open-meteo (one call, comma lists)
    om = None
    try:
        url = OPEN_METEO_URL.format(lats=",".join(f"{v:.6f}" for v in lats), lons=",".join(f"{v:.6f}" for v in lons))
        om = np.array(json.loads(http_get(url, timeout=30))["elevation"], dtype=np.float64)
    except Exception as e:  # noqa: BLE001
        result["open_meteo"] = {"error": repr(e)}
    ep = np.full(n_points, np.nan)
    ep_err = None
    for i in range(n_points):
        try:
            j = json.loads(http_get(EPQS_URL.format(lon=f"{lons[i]:.6f}", lat=f"{lats[i]:.6f}"), timeout=25, retries=2))
            ep[i] = float(j["value"])
        except Exception as e:  # noqa: BLE001
            ep_err = repr(e)
    for i in range(n_points):
        result["points"].append({
            "lon": round(float(lons[i]), 6), "lat": round(float(lats[i]), 6),
            "dem_m": round(float(dem_vals[i]), 1),
            "open_meteo_m": None if om is None else round(float(om[i]), 1),
            "usgs_epqs_m": None if math.isnan(ep[i]) else round(float(ep[i]), 1),
            "terrain_slope_pct": round(float(slope_pct[i]), 1),
        })

    def stats(ref, label):
        ok = ~np.isnan(ref)
        if not ok.any():
            return {"error": "no values", "detail": ep_err if label == "usgs_epqs" else None}
        d = dem_vals[ok] - ref[ok]
        return {"n": int(ok.sum()), "mean_error_m": round(float(d.mean()), 2),
                "mean_abs_error_m": round(float(np.abs(d).mean()), 2),
                "rmse_m": round(float(np.sqrt((d ** 2).mean())), 2),
                "max_abs_error_m": round(float(np.abs(d).max()), 2),
                "note": ("open-meteo serves Copernicus GLO-90 (90 m) -- expect large differences on steep slopes"
                         if label == "open_meteo" else "USGS 3DEP 1 m, the best available truth")}
    if om is not None:
        result["open_meteo"] = stats(om, "open_meteo")
    result["usgs_epqs"] = stats(ep, "usgs_epqs")
    return result


# ----------------------------------------------------------------------------- trails

def resample_polyline(lons, lats, step=SAMPLE_STEP_M):
    lons = np.asarray(lons, dtype=np.float64)
    lats = np.asarray(lats, dtype=np.float64)
    seg = haversine_m(lons[:-1], lats[:-1], lons[1:], lats[1:])
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    L = float(cum[-1])
    if L <= 0:
        return np.array([0.0]), lons[:1], lats[:1], 0.0
    n = max(2, int(math.ceil(L / step)) + 1)
    d = np.linspace(0.0, L, n)
    return d, np.interp(d, cum, lons), np.interp(d, cum, lats), L


def window_grades(d, e, W):
    """Grade (%) over every W-metre window starting at each sample whose window fits.
    Positive = descending in travel direction. If the line is shorter than W, a single
    whole-length window is used (flagged by the caller)."""
    L = float(d[-1])
    if L <= 0:
        return np.array([0.0]), 0.0
    if L < W:
        return np.array([(e[0] - e[-1]) / L * 100.0]), L
    starts = d[d + W <= L + 1e-6]
    e0 = np.interp(starts, d, e)
    e1 = np.interp(starts + W, d, e)
    return (e0 - e1) / W * 100.0, W


def analyse_line(dem, lons, lats):
    """Resample, sample the DEM, orient downhill, compute stats. Returns dict with arrays."""
    d, ls, la, L = resample_polyline(lons, lats)
    e = dem.sample(ls, la)
    vertex_order_uphill = bool(e[-1] > e[0])
    if vertex_order_uphill:
        d = L - d[::-1]
        ls, la, e = ls[::-1], la[::-1], e[::-1]
    slope_pct, aspect = dem.slope_aspect(ls, la)
    g50, w50 = window_grades(d, e, MAX_WINDOW_M)
    g150, w150 = window_grades(d, e, SUSTAINED_WINDOW_M)
    i_max = int(np.argmax(g50))
    top_i, bot_i = int(np.argmax(e)), int(np.argmin(e))
    # travel bearing per step, weighted by step length
    if ls.size > 1:
        b = bearing_deg(ls[:-1], la[:-1], ls[1:], la[1:])
        travel_bearing = circ_mean_deg(b, np.diff(d))
    else:
        travel_bearing = None
    # profile at 25 m
    dp = np.arange(0.0, L, PROFILE_STEP_M)
    if dp.size == 0 or dp[-1] < L - 1e-6:
        dp = np.append(dp, L)
    ep = np.interp(dp, d, e)
    climb = float(np.sum(np.clip(np.diff(ep), 0, None)))
    stats = {
        "length_m": round(L, 1),
        "vertical_drop_m": round(float(e[top_i] - e[bot_i]), 1),
        "net_drop_m": round(float(e[0] - e[-1]), 1),
        "top_elev_m": round(float(e[top_i]), 1),
        "bottom_elev_m": round(float(e[bot_i]), 1),
        "avg_grade_pct": round(float((e[top_i] - e[bot_i]) / L * 100.0) if L > 0 else 0.0, 2),
        "max_grade_pct": round(float(g50.max()), 2),
        "max_grade_window_m": round(float(w50), 1),
        "max_grade_at_m": round(float(d[d + w50 <= L + 1e-6][i_max]) if L >= MAX_WINDOW_M else 0.0, 1),
        "sustained_grade_pct": round(float(g150.max()), 2),
        "sustained_window_m": round(float(w150), 1),
        "p90_grade_pct": round(float(np.percentile(g50, 90)), 2),
        "terrain_slope_pct_mean": round(float(slope_pct.mean()), 2),
        "terrain_slope_pct_p90": round(float(np.percentile(slope_pct, 90)), 2),
        "aspect_deg": None if (a := circ_mean_deg(aspect, slope_pct)) is None else round(a, 1),
        "bearing_deg": None if travel_bearing is None else round(travel_bearing, 1),
        "climb_m": round(climb, 1),
        "windows_truncated": bool(L < SUSTAINED_WINDOW_M),
    }
    return {
        "d": d, "lon": ls, "lat": la, "elev": e, "length": L,
        "slope_pct": slope_pct, "aspect": aspect, "g50": g50, "g150": g150,
        "profile": [[round(float(x), 1), round(float(y), 1)] for x, y in zip(dp, ep)],
        "stats": stats, "vertex_order_uphill": vertex_order_uphill,
        "top": [round(float(ls[top_i]), 6), round(float(la[top_i]), 6), round(float(e[top_i]), 1)],
        "bottom": [round(float(ls[bot_i]), 6), round(float(la[bot_i]), 6), round(float(e[bot_i]), 1)],
    }


def coords_array(a):
    return [[round(float(x), 6), round(float(y), 6), round(float(z), 1)] for x, y, z in zip(a["lon"], a["lat"], a["elev"])]


def build_segment(way, a):
    t = way.get("tags", {})
    return {
        "osm_way_id": way["id"],
        "osm_vertex_count": len(way["geometry"]),
        "vertex_order_uphill": a["vertex_order_uphill"],
        "osm_difficulty": t.get("piste:difficulty"),
        "grooming": t.get("piste:grooming"),
        "gladed": t.get("gladed") == "yes",
        "oneway": t.get("piste:oneway", t.get("oneway")),
        "coords": coords_array(a),
        "top": a["top"],
        "bottom": a["bottom"],
        "stats": a["stats"],
        "profile": a["profile"],
    }


def chain_segments(analyses):
    """Order segments top->bottom and chain them if each one's start is within
    ENDPOINT_SNAP_M of the previous one's end. Returns (ordered_indices, chained_bool)."""
    order = sorted(range(len(analyses)), key=lambda i: -analyses[i]["elev"][0])
    if len(order) == 1:
        return order, True
    remaining = order[:]
    chain = [remaining.pop(0)]
    while remaining:
        last = analyses[chain[-1]]
        best, best_d = None, None
        for i in remaining:
            a = analyses[i]
            dist = float(haversine_m(last["lon"][-1], last["lat"][-1], a["lon"][0], a["lat"][0]))
            if best_d is None or dist < best_d:
                best, best_d = i, dist
        if best_d is not None and best_d <= ENDPOINT_SNAP_M:
            chain.append(best)
            remaining.remove(best)
        else:
            return order, False
    return chain, True


def merge_trail(name, ways, analyses, unnamed_info=None):
    order, chained = chain_segments(analyses)
    ways = [ways[i] for i in order]
    analyses = [analyses[i] for i in order]
    segs = [build_segment(w, a) for w, a in zip(ways, analyses)]
    L = sum(a["length"] for a in analyses)
    all_e = np.concatenate([a["elev"] for a in analyses])
    all_slope = np.concatenate([a["slope_pct"] for a in analyses])
    all_aspect = np.concatenate([a["aspect"] for a in analyses])
    all_g50 = np.concatenate([a["g50"] for a in analyses])
    top_seg = max(analyses, key=lambda a: a["elev"].max())
    bot_seg = min(analyses, key=lambda a: a["elev"].min())
    drop_sum = sum(a["stats"]["vertical_drop_m"] for a in analyses)
    if chained:
        profile, off = [], 0.0
        for a in analyses:
            for i, (x, y) in enumerate(a["profile"]):
                if profile and i == 0:
                    continue
                profile.append([round(x + off, 1), y])
            off += a["length"]
        profile_kind = "chained"
    else:
        profile = max(analyses, key=lambda a: a["length"])["profile"]
        profile_kind = "longest_segment"
    bearings = [a["stats"]["bearing_deg"] for a in analyses if a["stats"]["bearing_deg"] is not None]
    bweights = [a["length"] for a in analyses if a["stats"]["bearing_deg"] is not None]
    diffs = [w.get("tags", {}).get("piste:difficulty") for w in ways]
    diffs = [x for x in diffs if x]
    grooms = sorted({w.get("tags", {}).get("piste:grooming") for w in ways} - {None})
    oneways = sorted({w.get("tags", {}).get("piste:oneway", w.get("tags", {}).get("oneway")) for w in ways} - {None})
    trail = {
        "id": slugify(name) + "-" + "-".join(str(w["id"]) for w in sorted(ways, key=lambda w: w["id"])),
        "name": name,
        "unnamed": unnamed_info is not None,
        "osm_way_ids": [w["id"] for w in ways],
        "osm_difficulty": max(diffs, key=lambda x: DIFF_ORDER.get(x, -1)) if diffs else None,
        "osm_difficulty_all": sorted(set(diffs)),
        "grooming": grooms[0] if len(grooms) == 1 else (grooms or None),
        "gladed": any(w.get("tags", {}).get("gladed") == "yes" for w in ways),
        "oneway": oneways[0] if len(oneways) == 1 else (oneways or None),
        "segment_count": len(segs),
        "segments_chained": chained,
        "segments_relation": "single" if len(segs) == 1 else ("chained" if chained else "branches"),
        "top": top_seg["top"],
        "bottom": bot_seg["bottom"],
        "centroid": [round(float(np.mean(np.concatenate([a["lon"] for a in analyses]))), 6),
                     round(float(np.mean(np.concatenate([a["lat"] for a in analyses]))), 6)],
        "stats": {
            "length_m": round(L, 1),
            "vertical_drop_m": round(float(all_e.max() - all_e.min()), 1),
            "top_elev_m": round(float(all_e.max()), 1),
            "bottom_elev_m": round(float(all_e.min()), 1),
            "avg_grade_pct": round(drop_sum / L * 100.0, 2) if L > 0 else 0.0,
            "max_grade_pct": round(max(a["stats"]["max_grade_pct"] for a in analyses), 2),
            "sustained_grade_pct": round(max(a["stats"]["sustained_grade_pct"] for a in analyses), 2),
            "p90_grade_pct": round(float(np.percentile(all_g50, 90)), 2),
            "terrain_slope_pct_mean": round(float(all_slope.mean()), 2),
            "terrain_slope_pct_p90": round(float(np.percentile(all_slope, 90)), 2),
            "aspect_deg": None if (a := circ_mean_deg(all_aspect, all_slope)) is None else round(a, 1),
            "bearing_deg": None if not bearings else round(circ_mean_deg(bearings, bweights), 1),
            "climb_m": round(sum(a["stats"]["climb_m"] for a in analyses), 1),
            "windows_truncated": any(a["stats"]["windows_truncated"] for a in analyses),
            "any_vertex_order_uphill": any(a["vertex_order_uphill"] for a in analyses),
            "max_segment_length_m": round(max(a["length"] for a in analyses), 1),
            "max_segment_drop_m": round(max(a["stats"]["vertical_drop_m"] for a in analyses), 1),
        },
        "profile": profile,
        "profile_kind": profile_kind,
        "segments": segs,
    }
    if unnamed_info:
        trail.update(unnamed_info)
    return trail


# ----------------------------------------------------------------------------- lifts / boundary

def build_lifts(dem, aerial_ways):
    lifts, stations = [], []
    for w in aerial_ways:
        t = w.get("tags", {})
        kind = t.get("aerialway")
        lons = np.array([g["lon"] for g in w["geometry"]])
        lats = np.array([g["lat"] for g in w["geometry"]])
        e = dem.sample(lons, lats)
        if kind == "station":
            stations.append({
                "osm_way_id": w["id"], "name": t.get("name"),
                "centroid": [round(float(lons.mean()), 6), round(float(lats.mean()), 6), round(float(e.mean()), 1)],
                "footprint": [[round(float(x), 6), round(float(y), 6)] for x, y in zip(lons, lats)],
                "tags": t,
            })
            continue
        reversed_order = bool(e[0] > e[-1])
        if reversed_order:
            lons, lats, e = lons[::-1], lats[::-1], e[::-1]
        seg = haversine_m(lons[:-1], lats[:-1], lons[1:], lats[1:])
        name = t.get("name") or f"Unnamed {kind.replace('_', ' ')}"
        lifts.append({
            "id": slugify(name) + "-" + str(w["id"]),
            "osm_way_id": w["id"],
            "name": name,
            "named": "name" in t,
            "type": kind,
            "side": LIFT_SIDE.get(name, "Unknown"),
            "polyline": [[round(float(x), 6), round(float(y), 6), round(float(z), 1)] for x, y, z in zip(lons, lats, e)],
            "bottom": [round(float(lons[0]), 6), round(float(lats[0]), 6), round(float(e[0]), 1)],
            "top": [round(float(lons[-1]), 6), round(float(lats[-1]), 6), round(float(e[-1]), 1)],
            "bottom_elev_m": round(float(e[0]), 1),
            "top_elev_m": round(float(e[-1]), 1),
            "vertical_m": round(float(e[-1] - e[0]), 1),
            "length_m": round(float(seg.sum()), 1),
            "osm_order_was_top_to_bottom": reversed_order,
            "capacity_per_hour": int(t["aerialway:capacity"]) if t.get("aerialway:capacity", "").isdigit() else None,
            "duration_min": float(t["aerialway:duration"]) if re.fullmatch(r"[\d.]+", t.get("aerialway:duration", "")) else None,
            "occupancy": int(t["aerialway:occupancy"]) if t.get("aerialway:occupancy", "").isdigit() else None,
            "tags": t,
        })
    lifts.sort(key=lambda l: l["name"])
    known = [l for l in lifts if l["side"] != "Unknown"]
    for l in lifts:
        if l["side"] == "Unknown" and known:
            dd = haversine_m(l["bottom"][0], l["bottom"][1], np.array([k["bottom"][0] for k in known]), np.array([k["bottom"][1] for k in known]))
            k = known[int(np.argmin(dd))]
            l["side"] = k["side"]
            l["side_source"] = f"nearest known lift bottom: {k['name']} ({float(dd.min()):.0f} m)"
        else:
            l["side_source"] = "LIFT_SIDE table"
    return lifts, stations


def stitch_rings(members, tol_m=2.0):
    """Chain relation member ways (with geometry) into closed rings by endpoint matching."""
    ways = [{"ref": m["ref"], "role": m.get("role"), "pts": [[g["lon"], g["lat"]] for g in m["geometry"]]}
            for m in members if m.get("type") == "way" and m.get("geometry")]
    rings = []
    while ways:
        cur = ways.pop(0)
        ring = list(cur["pts"])
        refs = [cur["ref"]]
        role = cur["role"]
        progress = True
        while progress and float(haversine_m(ring[0][0], ring[0][1], ring[-1][0], ring[-1][1])) > tol_m:
            progress = False
            for i, w in enumerate(ways):
                p = w["pts"]
                if float(haversine_m(ring[-1][0], ring[-1][1], p[0][0], p[0][1])) <= tol_m:
                    ring.extend(p[1:]); ways.pop(i); refs.append(w["ref"]); progress = True; break
                if float(haversine_m(ring[-1][0], ring[-1][1], p[-1][0], p[-1][1])) <= tol_m:
                    ring.extend(p[::-1][1:]); ways.pop(i); refs.append(w["ref"]); progress = True; break
                if float(haversine_m(ring[0][0], ring[0][1], p[-1][0], p[-1][1])) <= tol_m:
                    ring = p[:-1] + ring; ways.pop(i); refs.append(w["ref"]); progress = True; break
                if float(haversine_m(ring[0][0], ring[0][1], p[0][0], p[0][1])) <= tol_m:
                    ring = p[::-1][:-1] + ring; ways.pop(i); refs.append(w["ref"]); progress = True; break
        closed = float(haversine_m(ring[0][0], ring[0][1], ring[-1][0], ring[-1][1])) <= tol_m
        if closed and ring[0] != ring[-1]:
            ring.append(ring[0])
        rings.append({"role": role, "osm_way_ids": refs, "closed": closed, "coords": ring})
    return rings


def ring_area_km2(ring):
    lat0 = math.radians(sum(p[1] for p in ring) / len(ring))
    xs = [math.radians(p[0]) * R_EARTH_M * math.cos(lat0) for p in ring]
    ys = [math.radians(p[1]) * R_EARTH_M for p in ring]
    a = 0.0
    for i in range(len(ring) - 1):
        a += xs[i] * ys[i + 1] - xs[i + 1] * ys[i]
    return abs(a) / 2.0 / 1e6


def build_boundary(relation):
    rings = stitch_rings(relation["members"])
    outers = [r for r in rings if r["role"] == "outer" and r["closed"]]
    inners = [r for r in rings if r["role"] == "inner" and r["closed"]]
    open_rings = [r for r in rings if not r["closed"]]
    if len(outers) == 1:
        geom = {"type": "Polygon", "coordinates": [[[round(x, 7), round(y, 7)] for x, y in outers[0]["coords"]]]
                + [[[round(x, 7), round(y, 7)] for x, y in r["coords"]] for r in inners]}
    else:
        geom = {"type": "MultiPolygon", "coordinates": [[[[round(x, 7), round(y, 7)] for x, y in r["coords"]]] for r in outers]}
    lons = [p[0] for r in outers for p in r["coords"]]
    lats = [p[1] for r in outers for p in r["coords"]]
    feature = {
        "type": "Feature",
        "geometry": geom,
        "properties": {
            "name": relation.get("tags", {}).get("name"),
            "osm_relation_id": relation["id"],
            "tags": relation.get("tags", {}),
            "rings": [{"role": r["role"], "osm_way_ids": r["osm_way_ids"], "closed": r["closed"], "vertex_count": len(r["coords"])} for r in rings],
            "open_rings_dropped": [r["osm_way_ids"] for r in open_rings],
            "area_km2": round(sum(ring_area_km2(r["coords"]) for r in outers), 3),
            "bbox": {"min_lon": min(lons), "min_lat": min(lats), "max_lon": max(lons), "max_lat": max(lats)},
            "coordinate_order": "[lon, lat] (GeoJSON), WGS84 / EPSG:4326",
        },
    }
    return feature, outers


# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zoom", type=int, default=14)
    ap.add_argument("--skip-verify", action="store_true", help="skip the open-meteo / USGS DEM check")
    ap.add_argument("--offline", action="store_true", help="never hit the network (needs cached tiles)")
    args = ap.parse_args()

    raw = json.loads(RAW_PATH.read_text())
    elements = raw["elements"]
    piste_ways = [e for e in elements if e["type"] == "way" and e.get("tags", {}).get("piste:type") == "downhill" and e.get("geometry")]
    aerial_ways = [e for e in elements if e["type"] == "way" and "aerialway" in e.get("tags", {}) and e.get("geometry")]
    relations = [e for e in elements if e["type"] == "relation" and e.get("tags", {}).get("landuse") == "winter_sports"]
    piste_relations = [e for e in elements if e["type"] == "relation" and e.get("tags", {}).get("piste:type") == "downhill"]
    print(f"[osm] {len(piste_ways)} piste ways, {len(aerial_ways)} aerialway ways, {len(relations)} resort relation(s), "
          f"{len(piste_relations)} piste relation(s); osm base {raw.get('osm3s', {}).get('timestamp_osm_base')}")
    issues = []
    if piste_relations:
        issues.append(f"{len(piste_relations)} piste relation(s) present in the dump but ignored (only ways are processed)")

    # ---- DEM
    elevation_source = "terrarium"
    try:
        dem = fetch_terrarium_dem(args.zoom, offline=args.offline)
    except Exception as e:  # noqa: BLE001
        print(f"[dem] terrarium tiles unavailable ({e!r}); falling back to open-meteo grid", file=sys.stderr)
        if args.offline:
            raise
        dem = fetch_open_meteo_grid_dem(args.zoom)
        elevation_source = "open-meteo-fallback"
        issues.append("DEM is an open-meteo (90 m Copernicus) fallback grid, not AWS terrarium tiles")
    meta, png_path, f32_path = save_dem(dem)
    if not args.skip_verify and not args.offline:
        print("[dem] verifying against open-meteo and USGS EPQS ...")
        meta["verification"] = verify_dem(dem, piste_ways)
        print(f"[dem] verification: {json.dumps({k: v for k, v in meta['verification'].items() if k != 'points'})}")
    else:
        meta["verification"] = {"skipped": True}
    dem.outside_count = 0

    # ---- trails: analyse every way
    analyses = {}
    for w in piste_ways:
        lons = [g["lon"] for g in w["geometry"]]
        lats = [g["lat"] for g in w["geometry"]]
        if len(lons) < 2:
            issues.append(f"way {w['id']} has <2 vertices; skipped")
            continue
        analyses[w["id"]] = analyse_line(dem, lons, lats)
    if dem.outside_count:
        issues.append(f"{dem.outside_count} sample points fell outside the DEM raster and were clamped")

    named = {}
    unnamed = []
    for w in piste_ways:
        if w["id"] not in analyses:
            continue
        name = w.get("tags", {}).get("name")
        if name:
            named.setdefault(name.strip(), []).append(w)
        else:
            unnamed.append(w)

    trails = []
    merged_names = []
    for name, ws in sorted(named.items(), key=lambda kv: kv[0].lower()):
        t = merge_trail(name, ws, [analyses[w["id"]] for w in ws])
        if len(ws) > 1:
            merged_names.append((name, [w["id"] for w in ws], t["segments_chained"]))
        trails.append(t)

    # Unnamed ways: kept as their own trails, labelled by the nearest named trail.
    # They are NOT merged into named trails because many are connectors that touch two
    # or more named runs, so attaching them would corrupt the named run's stats.
    named_pts = []
    for t in trails:
        for s in t["segments"]:
            for c in s["coords"]:
                named_pts.append((c[0], c[1], t["name"]))
    np_lon = np.array([p[0] for p in named_pts])
    np_lat = np.array([p[1] for p in named_pts])
    np_name = [p[2] for p in named_pts]
    unnamed_trails = []
    for w in unnamed:
        a = analyses[w["id"]]
        # nearest named trail by minimum point-to-point distance
        best_name, best_d = None, None
        for lon, lat in zip(a["lon"], a["lat"]):
            dd = haversine_m(lon, lat, np_lon, np_lat)
            i = int(np.argmin(dd))
            if best_d is None or dd[i] < best_d:
                best_d, best_name = float(dd[i]), np_name[i]
        connects = set()
        for lon, lat in ((a["lon"][0], a["lat"][0]), (a["lon"][-1], a["lat"][-1])):
            dd = haversine_m(lon, lat, np_lon, np_lat)
            for i in np.nonzero(dd <= ENDPOINT_SNAP_M)[0]:
                connects.add(np_name[int(i)])
        info = {"nearest_named_trail": best_name, "nearest_named_trail_distance_m": round(best_d, 1),
                "connects_to": sorted(connects)}
        unnamed_trails.append((w, a, info))
    # name them, de-duplicating
    counts = {}
    for w, a, info in sorted(unnamed_trails, key=lambda x: x[0]["id"]):
        base = f"Unnamed (near {info['nearest_named_trail']})"
        counts[base] = counts.get(base, 0) + 1
        name = base if counts[base] == 1 else f"{base} #{counts[base]}"
        trails.append(merge_trail(name, [w], [a], unnamed_info=info))
    # fix "#1" for duplicated bases
    for t in trails:
        if t["unnamed"]:
            base = f"Unnamed (near {t['nearest_named_trail']})"
            if counts.get(base, 0) > 1 and t["name"] == base:
                t["name"] = base + " #1"
                t["id"] = slugify(t["name"]) + "-" + "-".join(str(i) for i in t["osm_way_ids"])

    # ---- lifts
    lifts, stations = build_lifts(dem, aerial_ways)
    for l in lifts:
        if l["side_source"] != "LIFT_SIDE table":
            issues.append(f"lift '{l['name']}' (way {l['osm_way_id']}) not in LIFT_SIDE table; side taken from {l['side_source']}")
        if l["osm_order_was_top_to_bottom"]:
            issues.append(f"lift '{l['name']}' (way {l['osm_way_id']}) is drawn top->bottom in OSM (convention is bottom->top); reversed")
        if l["vertical_m"] < 5:
            issues.append(f"lift '{l['name']}' (way {l['osm_way_id']}) has only {l['vertical_m']} m vertical")

    # ---- area + nearest lift
    # Three independent signals for which lift pod (and therefore which resort side) a run belongs to:
    #   (1) lift whose TOP is nearest the trail top          (what you ride up to reach it)
    #   (2) lift whose LINE is nearest the trail bottom      (where the run deposits you)
    #   (3) lift whose LINE is nearest the trail centroid    (what it runs alongside)
    # area = majority vote of the three sides; ridge runs that start at a California lift top and
    # drop into Nevada (or vice versa) make (1) disagree with (2)/(3), so the votes are stored and
    # area_confidence is "low" whenever they are not unanimous.
    lift_top_lon = np.array([l["top"][0] for l in lifts])
    lift_top_lat = np.array([l["top"][1] for l in lifts])
    line_lon, line_lat, line_idx = [], [], []
    for li, l in enumerate(lifts):
        pl = l["polyline"]
        for a, b in zip(pl[:-1], pl[1:]):
            n = max(1, int(float(haversine_m(a[0], a[1], b[0], b[1])) / 10.0))
            for k in range(n + 1):
                f = k / n
                line_lon.append(a[0] + (b[0] - a[0]) * f)
                line_lat.append(a[1] + (b[1] - a[1]) * f)
                line_idx.append(li)
    line_lon, line_lat = np.array(line_lon), np.array(line_lat)

    def nearest_line(lon, lat):
        dd = haversine_m(lon, lat, line_lon, line_lat)
        k = int(np.argmin(dd))
        return line_idx[k], float(dd[k])

    low_conf = []
    for t in trails:
        dd = haversine_m(t["top"][0], t["top"][1], lift_top_lon, lift_top_lat)
        i = int(np.argmin(dd))
        j, dj = nearest_line(t["bottom"][0], t["bottom"][1])
        k, dk = nearest_line(t["centroid"][0], t["centroid"][1])
        t["nearest_lift"] = {"id": lifts[i]["id"], "name": lifts[i]["name"], "distance_m": round(float(dd[i]), 1),
                             "note": "lift whose TOP is closest to the trail top"}
        t["lift_at_bottom"] = {"id": lifts[j]["id"], "name": lifts[j]["name"], "distance_m": round(dj, 1),
                               "note": "lift LINE closest to the trail bottom point"}
        t["lift_at_centroid"] = {"id": lifts[k]["id"], "name": lifts[k]["name"], "distance_m": round(dk, 1),
                                 "note": "lift LINE closest to the trail centroid"}
        votes = {"nearest_lift_top": lifts[i]["side"], "lift_at_bottom": lifts[j]["side"], "lift_at_centroid": lifts[k]["side"]}
        sides = list(votes.values())
        area = max(set(sides), key=sides.count)
        t["area"] = area
        t["area_votes"] = votes
        t["area_confidence"] = "high" if len(set(sides)) == 1 else "low"
        if t["area_confidence"] == "low":
            low_conf.append(f"{t['name']} -> {area} (" + ", ".join(f"{k2}={v2[:2]}" for k2, v2 in votes.items()) + ")")
    if low_conf:
        issues.append(f"{len(low_conf)} trails where the three lift-proximity signals disagree on California/Nevada "
                      f"(ridge/connector runs; majority taken, area_confidence='low'): " + "; ".join(low_conf))

    # ---- boundary
    boundary = None
    outers = []
    if relations:
        boundary, outers = build_boundary(relations[0])
        if boundary["properties"]["open_rings_dropped"]:
            issues.append(f"boundary: unclosed member chains dropped: {boundary['properties']['open_rings_dropped']}")
        outside = [t["name"] for t in trails if not any(point_in_ring(t["top"][0], t["top"][1], r["coords"]) for r in outers)]
        if outside:
            issues.append(f"{len(outside)}/{len(trails)} trail tops fall OUTSIDE the OSM winter_sports boundary relation "
                          f"(relation covers only part of the resort, bbox {boundary['properties']['bbox']}); e.g. {outside[:6]}")
    else:
        issues.append("no landuse=winter_sports relation found; boundary.json not written")

    # ---- data-quality notes
    uphill = [(t["name"], s["osm_way_id"]) for t in trails for s in t["segments"] if s["vertex_order_uphill"]]
    if uphill:
        issues.append(f"{len(uphill)} piste ways are drawn uphill in OSM (vertex order reversed for stats): "
                      + ", ".join(f"{n} ({i})" for n, i in uphill[:12]) + (" ..." if len(uphill) > 12 else ""))
    short = [t["name"] for t in trails if t["stats"]["length_m"] < SUSTAINED_WINDOW_M]
    if short:
        issues.append(f"{len(short)} trails shorter than {SUSTAINED_WINDOW_M:.0f} m: sustained/max windows truncated to the whole length: {short[:8]}")
    climby = [(t["name"], t["stats"]["climb_m"]) for t in trails if t["stats"]["climb_m"] > 15]
    if climby:
        issues.append(f"{len(climby)} trails have >15 m of uphill along the travel direction (traverses/road-like or DEM noise): "
                      + ", ".join(f"{n} (+{c:.0f} m)" for n, c in sorted(climby, key=lambda x: -x[1])[:10]))
    nodiff = [t["name"] for t in trails if not t["osm_difficulty"]]
    if nodiff:
        issues.append(f"{len(nodiff)} trails have no piste:difficulty tag: {nodiff}")
    mixed = [t["name"] for t in trails if len(t["osm_difficulty_all"]) > 1]
    if mixed:
        issues.append(f"trails with conflicting piste:difficulty across segments (hardest kept): {mixed}")
    far = [(t["name"], t["lift_at_bottom"]["distance_m"]) for t in trails if t["lift_at_bottom"]["distance_m"] > 400]
    if far:
        issues.append(f"{len(far)} trails whose bottom is >400 m from any lift line (end on another run / mid-canyon): "
                      + ", ".join(f"{n} ({d:.0f} m)" for n, d in far[:10]))
    flat = [t["name"] for t in trails if t["stats"]["avg_grade_pct"] < 3]
    if flat:
        issues.append(f"{len(flat)} trails with avg grade <3% (cat tracks / connectors tagged as downhill pistes): {flat[:10]}")

    # ---- write outputs
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    common = {
        "generated": now,
        "source": "OpenStreetMap via Overpass API (data/raw/heavenly_osm.json); elevation from " + dem.source["name"],
        "license": "OpenStreetMap data: ODbL 1.0 (c) OpenStreetMap contributors. Elevation: AWS Terrain Tiles (public domain / see dem_meta.json attribution)",
        "osm_timestamp": raw.get("osm3s", {}).get("timestamp_osm_base"),
    }
    methods = {
        "coordinate_order": "[lon, lat, elev_m] (GeoJSON order), WGS84",
        "sampling": f"each OSM way is resampled to equal steps of <= {SAMPLE_STEP_M:.0f} m along the polyline (haversine, R = {R_EARTH_M} m); elevation bilinear from the DEM",
        "orientation": "downhill direction is determined from DEM elevation (start vs end), not OSM vertex order; segments/coords/profile are stored top->bottom; vertex_order_uphill flags ways drawn uphill in OSM",
        "grade": "percent = 100 * vertical / horizontal distance",
        "avg_grade_pct": "(top_elev - bottom_elev) / length; for merged trails sum(segment drops) / sum(segment lengths)",
        "max_grade_pct": f"steepest {MAX_WINDOW_M:.0f} m window (elevation interpolated at exact window ends); max_grade_at_m = distance from the top where that window starts",
        "sustained_grade_pct": f"steepest {SUSTAINED_WINDOW_M:.0f} m window; windows_truncated=true means the way is shorter than the window and the whole length was used",
        "p90_grade_pct": f"90th percentile of all {MAX_WINDOW_M:.0f} m window grades",
        "terrain_slope_pct": "magnitude of the DEM gradient at each sample point (true fall-line steepness, independent of the trail's centreline direction)",
        "aspect_deg": "slope-weighted circular mean of the DEM downhill aspect at the sample points (compass, 0=N 90=E): which way the terrain faces",
        "bearing_deg": "length-weighted circular mean of the travel direction top->bottom (compass)",
        "climb_m": f"total uphill along the travel direction on the {PROFILE_STEP_M:.0f} m profile",
        "profile": f"[distance_from_top_m, elev_m] every {PROFILE_STEP_M:.0f} m plus the end point; for multi-segment trails 'chained' if segments join end-to-start within {ENDPOINT_SNAP_M:.0f} m, else the longest segment's profile",
        "merging": "ways sharing the same name are merged into one trail; stats aggregate as total length (sum of all segments, including parallel branches -- see max_segment_length_m for the longest single line), max of max/sustained grades, overall top-bottom drop; segments_relation is 'chained' (end-to-start), 'branches' (parallel/forked lines) or 'single'",
        "unnamed": "unnamed ways are kept as separate trails named 'Unnamed (near <nearest named trail>)' (nearest by minimum point distance); connects_to lists named trails within 10 m of either endpoint; they are never merged into named trails",
        "id": "slug(name) + '-' + sorted OSM way ids (stable while OSM way ids are stable)",
        "area": "resort side (California/Nevada) by majority vote of three lift-proximity signals: side of nearest_lift (lift TOP nearest the trail top), side of lift_at_bottom (lift LINE nearest the trail bottom point) and side of lift_at_centroid (lift LINE nearest the trail centroid). Lifts get their side from Heavenly's trail map (LIFT_SIDE in build_trails.py). area_votes holds the three sides and area_confidence is 'low' when they disagree (ridge/connector runs). This is the resort's marketing side, not the surveyed CA/NV state line",
        "osm_difficulty": "piste:difficulty (easy/intermediate/advanced/expert); hardest kept when segments disagree",
    }
    trails_out = dict(common, dem={"meta": "data/dem/dem_meta.json", "png": "data/dem/heavenly_dem.png", "f32": "data/dem/heavenly_dem.f32"},
                      methods=methods, trail_count=len(trails), lift_count=len(lifts),
                      data_quality_issues=issues, trails=trails)
    (DATA_DIR / "trails.json").write_text(json.dumps(trails_out, indent=1))
    (DATA_DIR / "lifts.json").write_text(json.dumps(dict(common, lift_count=len(lifts), lifts=lifts, stations=stations,
                                                          methods={"polyline": "[lon, lat, elev_m] ordered bottom->top (by DEM elevation)",
                                                                   "side": "California/Nevada from LIFT_SIDE table (Heavenly trail map)"}), indent=1))
    if boundary:
        (DATA_DIR / "boundary.json").write_text(json.dumps(dict(common, **boundary), indent=1))
    (DEM_DIR / "dem_meta.json").write_text(json.dumps(dict(common, **meta), indent=1))

    # ---- summary table
    rows = sorted(trails, key=lambda t: -t["stats"]["max_grade_pct"])
    with (DATA_DIR / "trails_summary.csv").open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["name", "id", "area", "osm_difficulty", "grooming", "gladed", "length_m", "vertical_drop_m",
                     "avg_grade_pct", "max_grade_pct", "sustained_grade_pct", "p90_grade_pct", "terrain_slope_pct_mean",
                     "terrain_slope_pct_p90", "aspect_deg", "top_elev_m", "bottom_elev_m", "nearest_lift_top", "lift_at_bottom", "area_confidence", "segments", "segments_relation", "max_segment_length_m", "unnamed"])
        for t in rows:
            s = t["stats"]
            wr.writerow([t["name"], t["id"], t["area"], t["osm_difficulty"], t["grooming"], t["gladed"], s["length_m"],
                         s["vertical_drop_m"], s["avg_grade_pct"], s["max_grade_pct"], s["sustained_grade_pct"],
                         s["p90_grade_pct"], s["terrain_slope_pct_mean"], s["terrain_slope_pct_p90"], s["aspect_deg"],
                         s["top_elev_m"], s["bottom_elev_m"], t["nearest_lift"]["name"], t["lift_at_bottom"]["name"], t["area_confidence"], t["segment_count"],
                         t["segments_relation"], s.get("max_segment_length_m", s["length_m"]), t["unnamed"]])

    def fmt(t):
        s = t["stats"]
        return (f"{t['name'][:34]:<34} {str(t['osm_difficulty'])[:12]:<12} {t['area'][:10]:<10} {s['length_m']:>7.0f} "
                f"{s['vertical_drop_m']:>6.0f} {s['avg_grade_pct']:>5.1f} {s['max_grade_pct']:>5.1f} {s['sustained_grade_pct']:>5.1f}")
    hdr = f"{'name':<34} {'osm_diff':<12} {'area':<10} {'len_m':>7} {'drop':>6} {'avg%':>5} {'max%':>5} {'sus%':>5}"
    print("\n=== Top 15 by max grade (50 m window) ===\n" + hdr)
    for t in rows[:15]:
        print(fmt(t))
    print("\n=== Bottom 10 by max grade ===\n" + hdr)
    for t in rows[-10:]:
        print(fmt(t))
    print("\n=== Distribution by OSM difficulty (named trails only; p25/median/p75) ===")
    for diff in ["easy", "intermediate", "advanced", "expert", None]:
        grp = [t for t in trails if t["osm_difficulty"] == diff and not t["unnamed"]]
        if not grp:
            continue
        for key in ("avg_grade_pct", "sustained_grade_pct", "max_grade_pct"):
            v = np.array([t["stats"][key] for t in grp])
            print(f"  {str(diff):<13} n={len(grp):>3} {key:<20} p25={np.percentile(v,25):5.1f} med={np.median(v):5.1f} p75={np.percentile(v,75):5.1f} max={v.max():5.1f}")
    print(f"\n[merge] names with multiple ways: {merged_names}")
    print(f"[out] trails={len(trails)} (named {len(named)}, unnamed {len(unnamed)}), lifts={len(lifts)}, stations={len(stations)}")
    print("[issues]")
    for i in issues:
        print("  - " + i)
    print(f"[elevation_source] {elevation_source}: {dem.source['name']}")


if __name__ == "__main__":
    main()
