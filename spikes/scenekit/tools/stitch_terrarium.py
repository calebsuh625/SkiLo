#!/usr/bin/env python3
"""Stitch AWS Terrain Tiles (terrarium PNG, z14) into a cropped Heavenly DEM.
Usage: stitch_terrarium.py <tile_dir> <out_dir>
Outputs: dem16.png (uint16, elevation_m*10), dem.f32 (float32 LE row-major), meta.json
Grid is Web Mercator pixel space at zoom 14 (so columns are uniform in longitude,
rows are uniform in mercator-y; lat per row is given by inverse mercator)."""
import sys, os, json, math
import numpy as np
from PIL import Image

tile_dir, out_dir = sys.argv[1], sys.argv[2]
Z = 14; X0, X1, Y0, Y1 = 2731, 2737, 6262, 6268
BBOX = dict(min_lat=38.88, max_lat=38.99, min_lon=-119.99, max_lon=-119.85)
N = 2 ** Z; TILE = 256
W = (X1 - X0 + 1) * TILE; H = (Y1 - Y0 + 1) * TILE
mosaic = np.zeros((H, W), dtype=np.float64)
for tx in range(X0, X1 + 1):
    for ty in range(Y0, Y1 + 1):
        p = os.path.join(tile_dir, f"{Z}_{tx}_{ty}.png")
        a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float64)
        elev = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
        mosaic[(ty - Y0) * TILE:(ty - Y0 + 1) * TILE, (tx - X0) * TILE:(tx - X0 + 1) * TILE] = elev

def lon_to_px(lon): return (lon + 180) / 360 * N * TILE
def lat_to_py(lat):
    r = math.radians(lat)
    return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * N * TILE
def px_to_lon(px): return px / (N * TILE) * 360 - 180
def py_to_lat(py):
    n = math.pi - 2 * math.pi * py / (N * TILE)
    return math.degrees(math.atan(0.5 * (math.exp(n) - math.exp(-n))))

gx0 = X0 * TILE; gy0 = Y0 * TILE  # global pixel origin of mosaic
c0 = int(math.floor(lon_to_px(BBOX["min_lon"]) - gx0)); c1 = int(math.ceil(lon_to_px(BBOX["max_lon"]) - gx0))
r0 = int(math.floor(lat_to_py(BBOX["max_lat"]) - gy0)); r1 = int(math.ceil(lat_to_py(BBOX["min_lat"]) - gy0))
crop = mosaic[r0:r1 + 1, c0:c1 + 1]
rows, cols = crop.shape
# exact geographic extent of crop (pixel centers)
lon_w = px_to_lon(gx0 + c0 + 0.5); lon_e = px_to_lon(gx0 + c1 + 0.5)
lat_n = py_to_lat(gy0 + r0 + 0.5); lat_s = py_to_lat(gy0 + r1 + 0.5)
mid_lat = 0.5 * (lat_n + lat_s)
m_per_px = 40075016.686 * math.cos(math.radians(mid_lat)) / (N * TILE)
meta = dict(
    source="AWS Terrain Tiles (Mapzen terrarium), s3://elevation-tiles-prod/terrarium, zoom 14",
    license="Various (SRTM/NED/3DEP etc.) see https://github.com/tilezen/joerd/blob/master/docs/attribution.md",
    zoom=Z, tiles=dict(x0=X0, x1=X1, y0=Y0, y1=Y1), crop_px=dict(col0=c0, col1=c1, row0=r0, row1=r1),
    global_px_origin=dict(col=gx0 + c0, row=gy0 + r0),
    rows=int(rows), cols=int(cols),
    bbox_requested=BBOX,
    extent_pixel_centers=dict(lon_w=lon_w, lon_e=lon_e, lat_n=lat_n, lat_s=lat_s),
    grid="Web Mercator z14 pixel grid; col->lon linear; row->lat via inverse mercator",
    resolution_m_at_mid_lat=m_per_px,
    elev_min_m=float(crop.min()), elev_max_m=float(crop.max()), elev_mean_m=float(crop.mean()),
    dem16_png="dem16.png: uint16 = round(elev_m*10); elev_m = value/10",
    dem_f32="dem.f32: float32 little-endian, row-major, rows*cols, north row first",
    samples=[dict(row=int(r), col=int(c), elev_m=float(crop[r, c])) for r, c in [(0, 0), (rows // 2, cols // 2), (rows - 1, cols - 1), (100, 200)]],
)
Image.fromarray(np.round(crop * 10).clip(0, 65535).astype(np.uint16), mode="I;16").save(os.path.join(out_dir, "dem16.png"))
crop.astype("<f4").tofile(os.path.join(out_dir, "dem.f32"))
with open(os.path.join(out_dir, "meta.json"), "w") as f: json.dump(meta, f, indent=2)
print(json.dumps({k: meta[k] for k in ("rows", "cols", "resolution_m_at_mid_lat", "elev_min_m", "elev_max_m", "extent_pixel_centers")}, indent=1))
