#!/usr/bin/env python3
"""Make drape textures aligned to the DEM crop (same Web-Mercator pixel grid).
Usage: make_textures.py <spike_dir> <sat14_dir> <sat15_dir>
Outputs in spike_dir: hillshade_tex.png (hypsometric tint x hillshade, DEM res),
satellite_z14.jpg (7.4 m/px), satellite_z15.jpg (3.7 m/px, 2x DEM grid)."""
import sys, os, json, math
import numpy as np
from PIL import Image
spike, sat14, sat15 = sys.argv[1:4]
m = json.load(open(os.path.join(spike, "meta.json")))
rows, cols = m["rows"], m["cols"]; cp = m["crop_px"]; t = m["tiles"]
dem = np.fromfile(os.path.join(spike, "dem.f32"), dtype="<f4").reshape(rows, cols).astype(np.float64)
res = m["resolution_m_at_mid_lat"]
# hillshade: sun az 315 (NW), alt 45
dzdx = np.gradient(dem, res, axis=1); dzdy = np.gradient(dem, res, axis=0)  # row increases southward
slope = np.arctan(np.hypot(dzdx, dzdy)); aspect = np.arctan2(-dzdx, dzdy)
az, alt = math.radians(315), math.radians(45)
shade = np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(az - aspect)
shade = np.clip(shade, 0, 1)
# hypsometric ramp
stops = [(1500, (118, 136, 78)), (1950, (96, 132, 72)), (2300, (124, 142, 96)), (2600, (160, 150, 120)), (2850, (196, 196, 190)), (3070, (250, 250, 252))]
rgb = np.zeros((rows, cols, 3))
for k in range(3):
    rgb[..., k] = np.interp(dem, [s[0] for s in stops], [s[1][k] for s in stops])
water = (np.abs(dem - 1897.5) < 3) & (np.hypot(dzdx, dzdy) < 0.02)
rgb[water] = (64, 120, 184)
out = rgb * (0.35 + 0.65 * shade[..., None])
Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(os.path.join(spike, "hillshade_tex.png"))
print("hillshade_tex.png", rows, cols, "water px", int(water.sum()))
def stitch(d, z, x0, x1, y0, y1):
    T = 256; W = (x1 - x0 + 1) * T; H = (y1 - y0 + 1) * T
    mos = np.zeros((H, W, 3), dtype=np.uint8)
    for tx in range(x0, x1 + 1):
        for ty in range(y0, y1 + 1):
            mos[(ty - y0) * T:(ty - y0 + 1) * T, (tx - x0) * T:(tx - x0 + 1) * T] = np.asarray(Image.open(os.path.join(d, f"{z}_{tx}_{ty}.jpg")).convert("RGB"))
    return mos
s14 = stitch(sat14, 14, t["x0"], t["x1"], t["y0"], t["y1"])[cp["row0"]:cp["row1"] + 1, cp["col0"]:cp["col1"] + 1]
Image.fromarray(s14).save(os.path.join(spike, "satellite_z14.jpg"), quality=90); print("satellite_z14.jpg", s14.shape)
s15 = stitch(sat15, 15, 2 * t["x0"], 2 * t["x1"] + 1, 2 * t["y0"], 2 * t["y1"] + 1)[2 * cp["row0"]:2 * cp["row1"] + 2, 2 * cp["col0"]:2 * cp["col1"] + 2]
Image.fromarray(s15).save(os.path.join(spike, "satellite_z15.jpg"), quality=90); print("satellite_z15.jpg", s15.shape)
