# Heavenly Trail Difficulty Rating (1-100): Method

Status: v1 specification, calibrated 2026-11-01 against terrain-tile grade statistics for all 126 named
OSM downhill pistes at Heavenly. Companion files:

- `data/curated_modifiers.json` - hand-curated per-trail modifiers (gated, hike-to, chute, cliff exposure, narrow, traverse, moguls, trees) with notes and sources.
- `data/calibration_anchors.json` - per-trail inputs + expected rating for every trail, for a unit test of the Swift implementation.

## 0. TL;DR

```
rating = clamp( round( soft( gate( prior( base(S) + maxBonus + fatigue + terrain + hazards ) ) ) ), 1, 100 )
```

- `base(S)`: piecewise-linear curve on the **sustained grade** `S` (max mean grade over any 150 m horizontal window), 0..88.
- `maxBonus`: short steeper pitch above the sustained value, 0..4.2.
- `fatigue`: vertical-drop term, 0..10, only counts when the trail is steep enough to burn legs.
- `terrain`: moguls (5 + 0.10·S), trees (+8), ungroomed (+4 / +2).
- `hazards`: chute (+6) or narrow/traverse (+3), gated (+4), hike-to (+3), cliff exposure (0..10).
- `prior`: pulls halfway toward the OSM/resort colour's floor or ceiling when the computed value falls outside it.
- `gate`: anything behind an expert gate is at least 60.
- `soft`: identity up to 85, then an exponential approach to 100 so stacked modifiers cannot pin every chute at 100.

Result at Heavenly: Patsy's 6, Easy Street 9, Round-a-Bout 13, Olympic Downhill 36, Big Dipper 39, Mineshaft 52,
Ellie's 64, The Face 67, Gunbarrel 80, Hully Gully 84, Widow Maker 88, Bill's 92, Snake Eyes 95, Pipeline 96, The Fingers 97.
Full table in Appendix A.

## 1. Research

### 1.1 How North American resorts rate trails

- The colour/shape system is a **comparative** scale: trails are rated only against other trails at the same resort, and "a trail will be rated by its most difficult part, even if the rest of the trail is easy". Gradient is the primary input; width, sharpest turns, roughness, fall-line direction and grooming also count. (Wikipedia, *Piste*, https://en.wikipedia.org/wiki/Piste)
- Typical gradient bands quoted across sources: green circle about 6-25 % grade, blue square 25-40 %, black diamond 40 % and up, double-black "exceptionally steep" plus hazards (narrow, exposure, drop-offs, trees). (Wikipedia; SnowBrains, https://snowbrains.com/inconsistencies-in-classification-of-ski-slope-difficulty-ratings; PeakRankings, https://www.peakrankings.com/content/green-vs-blue-blue-vs-black-understanding-levels-of-ski-resort-terrain)
- There is no governing body enforcing the thresholds; resorts self-rate, and a green at Jackson Hole can be as hard as a blue at a small hill. Resorts also have a marketing incentive to inflate steepness. (SnowBrains; skibutlers.com)
- Europe uses similar grade caps (blue under ~25 %, red under ~40 %, black unbounded) but weights width, required speed, tight turns, off-camber and exposed rock more than angle. Scandinavia even publishes grade limits per colour (green <16 %, blue <27 %, red <47 %). (Wikipedia, *Piste*)
- Grade vs angle: grade % = 100·tan(angle). 25 % = 14°, 40 % = 21.8°, 58 % = 30°, 70 % = 35°, 84 % = 40°, 100 % = 45°.

Takeaway for a 1-100 scale: a single colour at Heavenly spans roughly 15 points of grade (blues run from 22 % to 46 % sustained in the terrain data), which is exactly the within-colour variance the app needs to expose.

### 1.2 What else drives perceived difficulty

Collected from the sources above plus skier trip reports (sections 1.4, 1.5):

| Factor | Why it matters | How the formula handles it |
|---|---|---|
| Sustained steepness | Determines the speed you must manage and how long you must hold technique. | `base(S)` on the 150 m-window max grade (the dominant term). |
| Max pitch | A short steep roll is scary but survivable; rated by hardest part in resort practice. | `maxBonus`, capped at 4.2 so one bank cannot dominate. |
| Moguls | Bumps convert speed control into absorption and timing; Heavenly's Gunbarrel bumps are "Volkswagen-sized". | `+5 + 0.10·S`: moguls on a steep slope hurt more than on a mellow one. |
| Trees / glades | Narrow lanes, hidden obstacles, variable snow, no grooming. SteepSeeker adds +8° for gladed runs. | `+8`. |
| Width / exposure / traverses | Cat-tracks, ridges and traverses restrict turn shape and raise consequence (Rim Trail's "stop-and-sidestep" spots above steep slopes). | `narrow`/`traverse` +3; `cliff_exposure` 0..10; traverses drop the fatigue term. |
| Gates / hike-to | Avalanche-controlled, ungroomed, committing, no bail-out, often a boot-pack or long traverse to exit (Killebrew). | `gated` +4 and a hard floor of 60; `hike_to` +3. |
| Chutes / cliffs / rocks | Confined fall line with a choke; a mandatory air (Snake Eyes) is a different category of commitment. | `chute` +6; `cliff_exposure` scaled 0..1 -> 0..10. |
| Length / vertical | Leg fatigue degrades technique; 1,600 ft of bumps is harder than 300 ft of the same bumps. | `fatigue` = 2 pts per 100 m vertical, cap 10, gated by steepness. |
| Altitude | Heavenly tops out at 3,068 m; it affects endurance, not the trail itself. | Not in the static rating; mention in the fatigue model only via vertical. |
| Conditions | Ice, crud, thin cover, flat light change the same trail day to day. | Separate per-log **conditions multiplier** (section 7), never baked into the static rating. |

### 1.3 Slope-based rating approaches (OpenSkiMap, SteepSeeker, DIY surveys)

- **OpenStreetMap / OpenSkiMap.** `piste:difficulty` is a mapper judgement with values novice/easy/intermediate/advanced/expert/freeride/extreme; it is not derived from slope and is understood to fold in narrowness and moguls. OpenSkiMap renders it through a regional convention (`NORTH_AMERICA`: easy=green, intermediate=blue, advanced=black, expert=double-black) and treats unspecified grooming as `backcountry` for expert/freeride/extreme runs. Runs carry an `elevationProfile` built by resampling the line at even spacing. (OSM wiki Key:piste:difficulty, https://wiki.openstreetmap.org/wiki/Key:piste:difficulty; openskidata-format `Run.ts`, https://github.com/russellporter/openskidata-format)
- **SteepSeeker** (steepseeker.com/about) rates every US trail by the **steepest sustained section** in degrees: v2 uses a 150 ft (~46 m) window (v1 used ~30 m). Bands: 0-16° beginner, 16-26° intermediate, 26-36° advanced, 36-46° expert, 46°+ extreme. Modifiers are added in degrees: gladed +8°, ungroomed/moguls +5°, hazardous +5° (rare), typical weather +0..6°. Data: OSM lines + USGS 3DEP (≤10 m). Known criticisms (SkiTalk thread 39106): a 100-150 ft window is noisy (a cut road or lidar treetops can create a phantom steep section) and resort rankings based on the five hardest runs are contentious. Our design answers this with a longer 150 m sustained window as the main term, a capped 50 m max-pitch bonus, and the OSM prior as a sanity blend.
- **DIY Google Earth survey** (DCSki forum 37293): the steepest ~136 ft of **Gunbarrel measures 31.6°** (62 % grade). Our terrain-tile max-50 m value for Gunbarrel is 62.3 %, i.e. the pipeline reproduces an independent measurement.
- **mahsu/ski-resort-analysis** ranks resorts from OpenSkiMap data by average pitch, max pitch and run length (no published thresholds).

### 1.4 Heavenly-specific knowledge (with sources)

Resort facts: 4,800 acres, base 2,029 m (6,657 ft), top 3,068 m (10,067 ft), 111 trails, 28 lifts, 15 % beginner / 53 % intermediate / 32 % advanced per the resort; skiresort.com counts 94 km of slopes (18 easy / 42 intermediate / 34 difficult) plus 40 km of ski routes, and names Mott Canyon (2 km, 400 m) "the most challenging terrain in the entire ski area". (skiheavenly.com mountain-info; skiresort.com/en/ski-resort/heavenly/slope-offering)

| Trail / area | What we learned | Source |
|---|---|---|
| Gunbarrel | "One of the most iconic bump runs with over 1,600 vertical feet of bumps"; the Face+Gunbarrel line drops ~1,600 ft (some say 1,700-1,800) to California Lodge; "North America's toughest black-diamond bump run"; bumps "the size of Volkswagens"; steepest 136 ft at 31.6°; Round-a-Bout and the flanking trees are the bail-outs; home of the Gunbarrel 25. | skiheavenly.com mountain-info; visitlaketahoe.com 9-iconic-trails; donsnotes.com/sports/ski_gunbarrel.html; dcski.com/forum/37293; xpatmatt.com Heavenly micro guide; snowbrains.com Gunbarrel 25 |
| The Face | Resort text: "a double-black mogul run unforgiving in its steepness ... drops 1,700 vertical feet into the equally challenging Gunbarrel and East Bowl moguls"; skied first thing off the Tram on powder days; groomed on occasion (lower part, Mar 2019). | onthesnow trail-map blurb; skiheavenly experience checklist; firsttracksonline 2019-03 |
| East Bowl / East Bowl Woods | Double-black bump bowl and steep trees skier's left of Gunbarrel; escape route when the bumps get too big. | donsnotes.com; firsttracksonline 2008-01 |
| Hogsback / West Bowl / Pistol | California-side blacks above Cal Lodge; Hogsback "is always rocky"; Pistol's shaded left side holds winter snow. OSM geometry puts Pistol 250 m from Gunbarrel Express, i.e. **not** a Mott chute. | firsttracksonline 2008-01, 2019-03; OSM |
| Olympic Downhill | "Heavenly's longest ski trail, 5.5 miles ... consistently medium-steep pitch ... nearly 2,000 vertical feet to the base of Stagecoach Express" (the 5.5 mi includes Stagecoach/Lower Stagecoach); "a fabulous blue square cruiser with fairly consistent, medium-grade pitch". | skiheavenly experience checklist; dcski.com/articles/1677 |
| Ridge Run | "The most scenic trail in skiing"; moderate pitch from the top of Sky Express. | skiheavenly trail-map page; visitlaketahoe |
| Patsy's / California Trail | Gentle green at the Tram top with lake views; Cal Trail and Ridge Run have the best views. | visitlaketahoe; skiheavenly mountain-info |
| Big Dipper, Liz's | "Well-prepared pistes for laying out big carving tracks"; Dipper lift lines cost 30 min on busy days. | worldsnowboardguide; skitalk 2022-23 Tahoe thread |
| Little Dipper | "Mona Lisa" bump face under the Dipper lift, left ungroomed; sees more bump skiers than any run in the region. | skitalk 2022-23; skitalk Rose-and-Heavenly thread |
| Ellie's, Express Line, Sky Canyon | Long blacks off Sky Express; Ellie's sometimes groomed from the top; "Sky had several long bump runs at a slightly milder pitch". Sky Canyon is a California-side single-black mogul run per OSM, **not** a Nevada chute. | firsttracksonline 2019-03; skitalk; OSM |
| North Bowl / Nevada Woods | "Steep, tree-covered terrain for advanced riders"; "outstanding storm skiing"; was being groomed and "mostly goes unskied" in 2019; Nevada Woods face east and fry after storms. | worldsnowboardguide; skitalk 2022-23; firsttracksonline 2019-03 |
| Milky Way Bowl | "The most challenging freeride terrain" on the Nevada side; open steeps above Mott/Killebrew accessed by foot from the ridge; tracks out quickly. | worldsnowboardguide; ski.com heavenly-expert-skiing (search snippet); firsttracksonline 2019-03 |
| Mott Canyon | Gate-accessed, 13 expert trails; "steep chutes and rock drops"; "40-degree pitches, deep snow and true north-facing aspects"; "steep and narrow with trees" rather than cliffy; slow Mott chair (900 ft vertical). Named lines: Widow Maker (choke near the bottom), Snake Eyes (usually a mandatory air at the choke; filled in during 2017 and 2019), Bill's (north-facing, the usual first Mott line), Hully Gully (choke under a cliff sign), The "Y" (longer leg is the common line), Stateline Chute (on the divide). | ski.com heavenly-expert-skiing (snippets); reddit r/Heavenly Mott first-timer (snippet); skitalk 2022-23, Rose-and-Heavenly; firsttracksonline 2008-01, 2017-04, 2019-03 |
| Killebrew Canyon | Gate-accessed, 8 expert trails, "typically the last terrain at Heavenly to open", more trees than Fulstone; 3/4-mile exit traverse (Rim Trail) with a short uphill, rocky stop-and-sidestep spots and very steep slopes below; chutes face east and fry; Pipeline is the classic line; Outer Limits is entered through the highest gate from Mott; Bob's Boulevard is the most east-facing; Boundary Chutes past Pipeline are the most north-facing. | ski.com; firsttracksonline 2008-01, 2017-04, 2019-03; skitalk 2022-23 (FATMAP aspect analysis) |
| Mott Canyon Trail | OSM geometry: 948 m, 121 m vertical, 19 % sustained, starting at the Mott chair top (2,846 m) and running east along the rim to the chute entrances (Widow Maker / Snake Eyes / Bill's tops at 2,725-2,750 m). It is the **rim access traverse**, black because of where it is, not how steep it is. | OSM geometry + terrain tiles |
| Pinnacles / Backstroke | OSM geometry puts both on the California side between Sky Express and Tamarack (Pinnacles centroid 480 m from Sky Express; 1.9 km, 619 m vertical, gladed). Not in Killebrew. Gate status unverified. | OSM geometry |
| Outlaw, Double Down | Outlaw is a Galaxy-area blue (22 % sustained); Double Down is a California-side black near Canyon Express with steep trees on skier's right. Neither is a Mott chute. | OSM geometry; firsttracksonline 2008-01 |
| Greens | Easy Street (Big Easy / Adventure Peak learning area), Maggie's (longest green, 1.8 km), Patsy's, Poma Trail, Boulder Bowl, Groove Park, Enchanted Forest; Heavenly "has few green runs" and some blacks branch off easy trails. | OSM; snow.com beginner guide; worldsnowboardguide |

### 1.5 What the terrain says (calibration run)

Method (reproducible; scripts in the session scratchpad `tools/calib_stats.py`, `tools/terrarium_elev.py`):

1. Elevation for all 2,545 unique piste vertices from AWS Terrain Tiles (terrarium PNG, z=15, ~3.7 m/px at 38.9° N, bilinear), 24 tiles. Verified reachable without a key (`https://s3.amazonaws.com/elevation-tiles-prod/terrarium/14/2730/6334.png` -> HTTP 200, 256x256 RGB). Open-Meteo returned HTTP 429 during the run, so it is a fallback only. Elevation range 2,025-3,048 m matches the resort's base/summit.
2. Each OSM way oriented downhill, resampled every 10 m of horizontal distance; grades computed as drop / horizontal distance x 100.
3. Per named trail (ways with the same name merged): `length_m` = sum of inclined lengths, `vertical_drop_m` = sum of drops, `avg_grade_pct` = vert / length, `max_grade_pct` = max over 50 m windows, `sustained_grade_pct` = max over 150 m windows, `p90_grade` = 90th percentile of 30 m-window grades (max taken across the trail's ways for the window stats).

Selected results (percent grade):

| Trail | OSM | length m | vert m | avg | sustained 150 m | max 50 m |
|---|---|---|---|---|---|---|
| Patsy's | easy | 554 | 68 | 12.2 | 15.5 | 24.7 |
| Easy Street | easy | 372 | 42 | 11.3 | 18.5 | 21.5 |
| Round-a-Bout | intermediate | 3,704 | 320 | 8.6 | 16.1 | 26.0 |
| Maggie's | easy | 1,835 | 231 | 12.6 | 19.3 | 20.6 |
| Olympic Downhill | intermediate | 2,133 | 473 | 22.2 | 30.2 | 35.3 |
| Ridge Run | intermediate | 2,596 | 433 | 16.7 | 29.4 | 32.5 |
| Big Dipper | intermediate | 2,012 | 355 | 17.7 | 34.6 | 37.1 |
| Mineshaft | intermediate | 659 | 192 | 29.1 | 45.7 | 46.6 |
| Ellie's | advanced/mogul | 1,202 | 380 | 31.6 | 44.2 | 46.9 |
| The Face | expert/mogul | 525 | 190 | 36.1 | 50.5 | 50.7 |
| Gunbarrel | expert/mogul | 636 | 283 | 44.5 | 58.9 | 62.3 |
| Milky Way Bowl | advanced/mogul | 409 | 195 | 47.6 | 59.1 | 63.1 |
| Hogsback | advanced/gladed | 1,205 | 468 | 38.8 | 62.7 | 63.2 |
| Widow Maker | expert/gladed | 400 | 175 | 43.7 | 57.0 | 64.6 |
| Snake Eyes | expert/gladed | 369 | 185 | 50.0 | 72.8 | 79.0 |
| Bill's | expert/gladed | 582 | 239 | 41.2 | 74.8 | 78.5 |
| Pipeline | expert/gladed | 476 | 223 | 46.9 | 76.5 | 84.8 |
| The Fingers | expert/gladed | 460 | 260 | 56.4 | 91.4 | 100.6 |
| Mott Canyon Trail | advanced | 948 | 121 | 12.8 | 19.0 | 19.8 |
| Rim Trail | expert | 732 | 59 | 8.1 | 16.5 | 26.9 |

Observations that shaped the formula:

- Blues span 22-46 % sustained (Outlaw/Sand Dunes to Mineshaft/Ponderosa); blacks span 34-66 %; double-blacks 16 % (traverses) to 91 %. A single colour is 15-30 rating points wide. This is the variance the user asked to expose.
- Mott/Killebrew lines cluster at 55-91 % sustained (29-42°), consistent with "40-degree pitches".
- Two double-black "trails" (Mott Canyon Trail, Rim Trail) are traverses with <20 % sustained grade. Grade alone would call them green; the resort calls them double-black because of where they are. Hence the OSM prior blend and the gated floor.
- DEM artefacts exist: Enchanted Forest (a kids' green) shows a 43 % max-50 m value from a short bank. Hence the max-pitch term is capped and ramped off below 30 % sustained.
- Caveats: terrain tiles measure bare ground, not the snow surface; the OSM line is a mapper's centreline and may not follow the steepest fall line (The Face reads 50 % here but is reputed steeper than Gunbarrel's 59 %); grooming/gladed tags are incomplete.

## 2. Inputs

From `data/trails.json` (computed by the pipeline, definitions in section 9):

| Field | Type | Meaning |
|---|---|---|
| `length_m` | Double | inclined length, all ways with this name |
| `vertical_drop_m` | Double | top minus bottom elevation (sum over ways) |
| `avg_grade_pct` | Double | 100·vert / horizontal length |
| `max_grade_pct` | Double | max mean grade over any 50 m horizontal window |
| `sustained_grade_pct` | Double | max mean grade over any 150 m horizontal window |
| `p90_grade` | Double | 90th percentile of 30 m-window grades (diagnostic; not used in v1 math) |
| `osm_difficulty` | String? | easy / intermediate / advanced / expert (null allowed) |
| `grooming` | String? | classic / mogul / backcountry / null |
| `gladed` | Bool | OSM `gladed=yes` |
| `aspect` | String | compass aspect of the mean fall line (used by the conditions UI only) |

From `data/curated_modifiers.json` (optional, keyed by exact OSM name):

| Key | Type | Default when absent | Meaning |
|---|---|---|---|
| `gated` | Bool | false | behind an expert-only gate |
| `hike_to` | Bool | false | boot-pack / long uphill traverse to reach |
| `chute` | Bool | false | confined fall line with a committing choke |
| `cliff_exposure` | 0..1 | 0 | 0.2 avoidable rock drops, 0.5 falls have consequences / mandatory sidestep, 0.7 usually-mandatory air, 1.0 cliff band |
| `narrow` | Bool | false | width restricts turn shape (cat track, ridge, lane < ~15 m) |
| `traverse` | Bool | false | access/exit traverse rather than a descent |
| `moguls_typical` | Bool? | `grooming == "mogul"` | bumped most days when open |
| `trees` | Bool? | `gladed` | skied through trees |
| `notes`, `source` | String | - | documentation only |

## 3. The formula (exact)

All grades in percent. `clamp(x,a,b) = min(max(x,a),b)`. `ramp(x,a,b) = clamp((x-a)/(b-a), 0, 1)`.

Let `S = sustained_grade_pct`, `M = max_grade_pct`, `V = vertical_drop_m`.

### 3.1 Base curve on sustained grade

`base(S)` is piecewise-linear through these knots (clamped flat outside the range):

| S % | 0 | 10 | 15 | 20 | 25 | 30 | 35 | 40 | 45 | 50 | 55 | 60 | 65 | 70 | 80 | 90 | 100 | 120 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base | 0 | 2 | 5 | 10 | 16 | 24 | 32 | 40 | 47 | 53 | 58 | 63 | 67 | 71 | 77 | 81 | 84 | 88 |

Design: slope ~1.6 pts per % grade through the green/blue range (15-40 %), where perceived difficulty rises fastest; slope ~1.0 through blacks (40-70 %); flattening above 70 % (35°) where consequences (hazards term) rather than pure angle separate lines. Green/blue/black colour thresholds (25 %, 40 %) land at 16 and 40; the SteepSeeker "advanced" threshold (26° = 49 %) lands at 52 and "expert" (36° = 73 %) at 73.

### 3.2 Max-pitch bonus

```
maxBonus = 0.35 · clamp(M − S, 0, 12) · ramp(S, 20, 30)        // 0 .. 4.2
```

Rewards a short pitch steeper than the sustained value (a steep roll-over or entrance), capped at 12 % above sustained, and switched off for mellow trails (S < 20 %) where the 50 m window mostly reflects DEM noise or a road cut.

### 3.3 Fatigue

```
fatigue = traverse ? 0 : min(10, 2.0 · V / 100) · ramp(S, 10, 30)   // 0 .. 10
```

Two points per 100 m of vertical, cap 10 (500 m). Scaled by steepness so a long road is not "hard". Traverses are exempt.

### 3.4 Terrain

```
moguls = moguls_typical ?? (grooming == "mogul")
trees  = trees ?? gladed
terrain = 0
if moguls           terrain += 5 + 0.10 · S                       // 7 at 20 %, 11 at 60 %
if trees            terrain += 8
else if !moguls:
    if grooming == "backcountry" or (grooming == nil and osm == "expert")   terrain += 4
    else if grooming == nil and osm == "advanced"                           terrain += 2
```

Moguls and trees can stack (Dipper Line). The ungroomed bonus follows OpenSkiMap's convention that unspecified grooming on an expert run means ungroomed; advanced with unknown grooming gets half credit.

### 3.5 Hazards (curated modifiers)

```
hazards = 0
if chute                     hazards += 6
else if narrow or traverse   hazards += 3
if gated                     hazards += 4
if hike_to                   hazards += 3
hazards += 10 · cliff_exposure
```

### 3.6 Raw score and OSM prior

```
raw = base(S) + maxBonus + fatigue + terrain + hazards
floor   = { easy: 0,  intermediate: 15, advanced: 45, expert: 62 }[osm]    // nil osm -> 0
ceiling = { easy: 30, intermediate: 58, advanced: 85, expert: 100 }[osm]   // nil osm -> 100
if raw < floor    raw = (raw + floor) / 2
if raw > ceiling  raw = (raw + ceiling) / 2
```

The resort's colour encodes knowledge the DEM cannot see (a 20 m entrance, rocks, exposure). We never trust it fully (that would re-create the colour buckets) but pull halfway toward the colour's band when the computed value falls outside it. Nil `osm_difficulty` means no prior.

### 3.7 Gated floor

```
if gated   raw = max(raw, 60)
```

Everything behind the Mott/Killebrew gates (including the access traverses) requires expert ability to be there at all. 60 is the Advanced/Expert boundary.

### 3.8 Soft cap and rounding

```
soft(x) = x                                   if x ≤ 85
        = 85 + 15 · (1 − exp(−(x − 85) / 15))  if x > 85      // slope 1 at the knee, asymptote 100
rating  = clamp(Int(round(soft(raw))), 1, 100)
```

The hardest line at Heavenly (The Fingers, raw 108) lands at 97; 100 is intentionally unreachable here so the scale stays absolute if other resorts are added later.

### 3.9 Worked examples (numbers from the calibration run)

| Trail | S | M | V | base | maxBonus | fatigue | terrain | hazards | raw | prior | gate | soft | rating |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Gunbarrel (expert, mogul) | 58.9 | 62.3 | 283 | 61.9 | 1.2 | 5.7 | 10.9 | 0 | 79.7 | 79.7 | 79.7 | 79.7 | **80** |
| Olympic Downhill (intermediate, classic) | 30.2 | 35.3 | 473 | 24.3 | 1.8 | 9.5 | 0 | 0 | 35.6 | 35.6 | 35.6 | 35.6 | **36** |
| Snake Eyes (expert, gladed; gated, chute, narrow, cliff 0.7) | 72.8 | 79.0 | 185 | 72.7 | 2.2 | 3.7 | 8 | 17 | 103.6 | 101.8 (ceiling 100) | 101.8 | 95.1 | **95** |
| Mott Canyon Trail (advanced, classic; gated, traverse, narrow, cliff 0.2) | 19.0 | 19.8 | 121 | 9.0 | 0 | 0 | 0 | 9 | 18.0 | 31.5 (floor 45) | 60 | 60 | **60** |
| Mineshaft (intermediate, classic) | 45.7 | 46.6 | 192 | 47.9 | 0.3 | 3.8 | 0 | 0 | 52.0 | 52.0 | 52.0 | 52.0 | **52** |

### 3.10 Swift implementation

```swift
import Foundation

struct TrailStats {
    var lengthM: Double
    var verticalDropM: Double
    var avgGradePct: Double
    var maxGradePct: Double          // 50 m window
    var sustainedGradePct: Double    // 150 m window
    var p90Grade: Double
    var osmDifficulty: String?       // easy | intermediate | advanced | expert
    var grooming: String?            // classic | mogul | backcountry
    var gladed: Bool
}

struct CuratedModifiers: Codable {
    var gated = false
    var hikeTo = false
    var chute = false
    var cliffExposure = 0.0          // 0...1
    var narrow = false
    var traverse = false
    var mogulsTypical: Bool? = nil   // nil -> use grooming == "mogul"
    var trees: Bool? = nil           // nil -> use gladed
    var notes: String? = nil
    var source: String? = nil

    enum CodingKeys: String, CodingKey {
        case gated, hikeTo = "hike_to", chute, cliffExposure = "cliff_exposure", narrow, traverse
        case mogulsTypical = "moguls_typical", trees, notes, source
    }
}

struct RatingBreakdown {
    var base, maxBonus, fatigue, terrain, hazards, raw, afterPrior, afterGate, soft: Double
    var rating: Int
}

enum DifficultyRating {
    static let baseKnots: [(Double, Double)] = [
        (0,0),(10,2),(15,5),(20,10),(25,16),(30,24),(35,32),(40,40),(45,47),(50,53),
        (55,58),(60,63),(65,67),(70,71),(80,77),(90,81),(100,84),(120,88)
    ]
    static let floors:   [String: Double] = ["easy": 0,  "intermediate": 15, "advanced": 45, "expert": 62]
    static let ceilings: [String: Double] = ["easy": 30, "intermediate": 58, "advanced": 85, "expert": 100]

    static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double { clamp((x - a) / (b - a), 0, 1) }

    static func piecewise(_ x: Double, _ knots: [(Double, Double)]) -> Double {
        if x <= knots[0].0 { return knots[0].1 }
        if x >= knots[knots.count - 1].0 { return knots[knots.count - 1].1 }
        for i in 1..<knots.count where x <= knots[i].0 {
            let (x0, y0) = knots[i - 1], (x1, y1) = knots[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return knots[knots.count - 1].1
    }

    static func breakdown(_ t: TrailStats, _ m: CuratedModifiers = CuratedModifiers()) -> RatingBreakdown {
        let S = t.sustainedGradePct, M = t.maxGradePct, V = t.verticalDropM
        let osm = t.osmDifficulty
        let moguls = m.mogulsTypical ?? (t.grooming == "mogul")
        let trees  = m.trees ?? t.gladed

        let base = piecewise(S, baseKnots)
        let maxBonus = 0.35 * clamp(M - S, 0, 12) * ramp(S, 20, 30)
        let fatigue = m.traverse ? 0 : min(10, 2.0 * V / 100) * ramp(S, 10, 30)

        var terrain = 0.0
        if moguls { terrain += 5 + 0.10 * S }
        if trees {
            terrain += 8
        } else if !moguls {
            if t.grooming == "backcountry" || (t.grooming == nil && osm == "expert") { terrain += 4 }
            else if t.grooming == nil && osm == "advanced" { terrain += 2 }
        }

        var hazards = 0.0
        if m.chute { hazards += 6 } else if m.narrow || m.traverse { hazards += 3 }
        if m.gated { hazards += 4 }
        if m.hikeTo { hazards += 3 }
        hazards += 10 * clamp(m.cliffExposure, 0, 1)

        let raw = base + maxBonus + fatigue + terrain + hazards
        let floor = osm.flatMap { floors[$0] } ?? 0
        let ceiling = osm.flatMap { ceilings[$0] } ?? 100
        var p = raw
        if p < floor { p = (p + floor) / 2 }
        if p > ceiling { p = (p + ceiling) / 2 }
        let g = m.gated ? max(p, 60) : p
        let s = g <= 85 ? g : 85 + 15 * (1 - exp(-(g - 85) / 15))
        let rating = Int(clamp(s.rounded(), 1, 100))
        return RatingBreakdown(base: base, maxBonus: maxBonus, fatigue: fatigue, terrain: terrain,
                               hazards: hazards, raw: raw, afterPrior: p, afterGate: g, soft: s, rating: rating)
    }

    static func rating(_ t: TrailStats, _ m: CuratedModifiers = CuratedModifiers()) -> Int {
        breakdown(t, m).rating
    }
}
```

`RatingBreakdown` is meant for the UI ("why is Gunbarrel an 80?"): show base / pitch / fatigue / terrain / hazards as a stacked bar.

### 3.11 Properties and tuning knobs

- **Monotone in steepness**: `base`, `maxBonus` (in M) and `fatigue` are non-decreasing in S and M; the prior and soft cap are monotone maps; so the rating never decreases when a trail gets steeper, holding everything else fixed.
- **Bounded**: raw ≤ 88 + 4.2 + 10 + (11 + 8) + (6 + 4 + 3 + 10) = 144 before the cap; soft(144) = 99.6; clamp to 100.
- **Spread**: at Heavenly the 126 named trails land 6-97 with 26 / 25 / 20 / 25 / 12 / 18 trails in the six display bands (Appendix A).
- Knobs most worth exposing in a debug panel: the base knots, the trees bonus (8), the gated floor (60), and the prior weight (0.5). Changing the window lengths (150 m / 50 m) in the pipeline changes S and M and requires re-tuning the knots.

## 4. Calibration anchors

Targets are what an experienced Heavenly skier would expect; tolerance is the acceptable deviation. All pass with the v1 constants (computed values from Appendix A). Where the computed value differs from the orchestrator's first guesses, the reason is given.

| Trail | Target | Tol | Computed | Why |
|---|---|---|---|---|
| Patsy's | 5 | 4 | 6 | Gentlest named green (15.5 % sustained), lake-view cruise off the Tram. |
| Easy Street | 6 | 4 | 9 | Wide learning-area green by Big Easy; 18.5 % sustained, 42 m vertical. |
| Round-a-Bout | 10 | 4 | 13 | 3.7 km road around The Face; mellow but narrow with a few 26 % rollers; blue by signage. |
| Maggie's | 12 | 4 | 11 | Longest green (1.8 km, 231 m); tiring for a first-week skier, never steep. |
| Skyline Trail | 14 | 4 | 11 | Ridge-top connector, 13 % sustained; blue only for length/exposure to wind. |
| California Trail | 28 | 5 | 31 | Long lake-view blue, 29.5 % sustained, 369 m vertical. |
| Ridge Run | 30 | 5 | 32 | "Most scenic trail", moderate pitch (29 %), 433 m of vertical adds fatigue. |
| Orion | 32 | 5 | 30 | Morning-sun blue off Dipper, 29 % sustained, 337 m. |
| Comet | 33 | 5 | 32 | Classic groomer, 31 % sustained. |
| Olympic Downhill | 36 | 5 | 36 | "Consistently medium-steep" (30 %) but 473 m vertical: the fatigue term lifts it above shorter blues. Orchestrator guess 45 was too high for a 30 % groomer. |
| Liz's | 38 | 5 | 40 | Big-carve groomer, 35 % sustained, 383 m. |
| Big Dipper | 39 | 5 | 39 | Wide carving piste off Dipper, 35 % sustained, 355 m. |
| Mineshaft | 51 | 5 | 52 | Steepest blue on the mountain (46 % sustained) - a "black in blue clothing". |
| Little Dipper | 56 | 5 | 59 | 43 % bump face under the Dipper lift, ungroomed by policy. |
| Sky Canyon | 57 | 5 | 58 | Single-black mogul run off Sky Express (43 %). Orchestrator's 92-98 guess assumed a Nevada chute; OSM geometry puts it on the California side. |
| Mott Canyon Trail | 60 | 4 | 60 | The rim access traverse from the Mott chair top (19 % sustained). Rated by the gated floor: you must be a 60 to be there. Orchestrator's 85 guess treated it as a chute. |
| North Bowl | 60 | 6 | 64 | Shaded Nevada bowl, 45 % sustained, bumps/trees. |
| Ellie's | 62 | 5 | 64 | Long black (380 m) with bumps most days; drops to ~55 with the "groomed today" condition. |
| The Face | 72 | 6 | 67 | Double-black bumps; DEM reads 50 % (OSM line likely off the steepest fall line). Keep within tolerance; revisit if a better centreline is traced. |
| Pinnacles | 70 | 6 | 69 | 1.9 km / 619 m gladed double-black on the California side; single-black in OSM; set `gated=true` if patrol gates it (-> ~73). |
| Gunbarrel | 82 | 4 | 80 | 59 % sustained, 283 m of VW-sized bumps; the benchmark "hardest bump run". |
| Hully Gully | 84 | 5 | 84 | Mott gully with a cliff-signed choke; 55 % sustained. |
| Hogsback | 84 | 5 | 86 | 63 % sustained for 468 m through rocks and trees; rarely in condition. |
| Milky Way Bowl | 82 | 5 | 86 | Open 59 % bowl, hike-to behind the gates, no trees or cliffs. |
| Widow Maker | 91 | 4 | 88 | 57 % sustained chute with a choke at the bottom. |
| Bill's | 90 | 5 | 92 | 75 % sustained (37°) but wider and north-facing; the usual first Mott line. |
| Snake Eyes | 96 | 3 | 95 | 73 % sustained choked chute with a usually-mandatory air. |
| Pipeline | 95 | 4 | 96 | The classic Killebrew chute, 76 % sustained, hike/traverse access. |
| The Fingers | 99 | 2 | 97 | Steepest line measured (91 % = 42°), finger chutes, Killebrew. |

Machine-readable copies of all 126 computed ratings with their inputs are in `data/calibration_anchors.json`.

**Cross-check against the pipeline's `data/trails.json`** (generated 2026-11-01T21:47Z by the data agent, same terrain-tile DEM, 15 m sampling, identical 50 m / 150 m window definitions): running the v1 formula on its `stats` gives ratings a median +1 above the calibration fixture (mean +0.99), with |diff| ≥ 4 only on short gladed lines where sampling changes the 150 m window (Dipper Woods +10, Nevada Woods +8, Stage Line +7, Cascade +4, Emily's Run +4, Galaxy Woods +4, Jack's +5, Southern Comfort +4). All 29 anchors pass on both inputs. Unit tests should feed the fixture's recorded inputs to the Swift function and compare with `expected_rating` exactly; the live `trails.json` should be compared against `target ± tol` only.

Field-name notes for the implementer: `trails.json` names the percentile `stats.p90_grade_pct` (90th percentile of 50 m windows), not `p90_grade`; `vertical_drop_m`, `max_grade_pct`, `sustained_grade_pct`, `osm_difficulty`, `grooming`, `gladed` match this spec. The pipeline also supplies `stats.terrain_slope_pct_p90` (fall-line steepness from the DEM gradient, independent of the centreline direction). A v1.1 refinement worth testing for runs whose OSM line is drawn off the fall line (The Face reads 50 % sustained but 'unforgiving in its steepness'): `S' = max(S, 0.85 · terrain_slope_pct_p90)`; it is not part of v1 because it was not calibrated.

## 5. Curated modifiers file

`data/curated_modifiers.json` maps exact OSM names to:

```json
{"gated": false, "hike_to": false, "chute": false, "cliff_exposure": 0.0, "narrow": false,
 "traverse": false, "moguls_typical": false, "trees": false, "notes": "...", "source": "..."}
```

Coverage: 90 trails curated; the remaining 36 blues/greens fall back to OSM tags (which is correct for them). Geographic assignment of the Nevada chutes was made from OSM geometry (Mott lines cluster at lat 38.930-38.935 within 250 m of the Mott Canyon chair; Killebrew lines at lat 38.925-38.929, 400-750 m from the chair with no lift of their own) cross-checked with trip reports. Every entry has a `source`; `cliff_exposure` values are judgement calls on the 0-1 scale defined in section 2 and are the first thing the user should tune after skiing a line.

## 6. Display bands and colour ramp

| Range | Band | Stop colour (light) | Stop colour (dark) |
|---|---|---|---|
| 1-20 | Beginner | `#2E9E5B` green | `#4CC27A` |
| 21-40 | Easy Intermediate | `#1F77D0` blue | `#4A9BE8` |
| 41-55 | Intermediate | `#4F46E5` indigo | `#7C74FF` |
| 56-70 | Advanced | `#2B2B36` charcoal | `#B9B9C8` |
| 71-85 | Expert | `#C62828` red | `#EF5350` |
| 86-100 | Extreme | `#FF6A00` orange | `#FF8C33` |

Continuous ramp: place the stops at ratings 1, 20, 40, 55, 70, 85, 100 and interpolate linearly in OKLCH (fallback: sRGB) so a 48 reads as blue-indigo and a 78 as dark red. Keep the traditional glyph (circle / square / diamond / double diamond from `osm_difficulty`) as a small secondary mark on the map so the familiar system is not lost. On the 3D map, colour the trail line by rating and dim completed ("crossed off") trails to 40 % opacity with a check badge.

## 7. Conditions multiplier (per logged run)

The static rating describes the trail on a normal day. When logging a run the user ticks conditions; the app stores the static rating, the multiplier and the **effective difficulty** `clamp(round(rating · k), 1, 100)` where `k` is the product of the chosen factors, clamped to [0.75, 1.35]:

| Group (pick one per group) | Factor |
|---|---|
| Surface: groomed/packed (default) | 1.00 |
| Surface: fresh powder ≤ 15 cm | 1.00 |
| Surface: deep powder > 15 cm | 1.05 on groomers; 0.92 if `moguls_typical` (bumps fill in) |
| Surface: chopped crud | 1.08 |
| Surface: firm / icy | 1.15 |
| Surface: spring slush / heavy | 1.05 |
| Surface: thin / rocky | 1.08 |
| Shape: bumped up today (normally groomed) | 1.15 |
| Shape: groomed today (normally bumps) | 0.85 |
| Visibility: flat light / fog | 1.05 |
| Weather: high wind / storm | 1.05 |

`aspect` drives default suggestions only: S/SW-facing trails (Maggie's Canyon, Rim Trail) get "spring slush" suggested after noon in March/April; N-facing Mott lines get "firm" suggested in the morning after a freeze.

## 8. Skill estimate and progression

Each log entry has: trail, date, effective difficulty `e` (section 7), outcome `o` in {clean = 1.0 (skied it confidently, linked turns, would do it again), survived = 0.5 (got down, not pretty), bailed = 0 (excluded)}.

**Recency weight**: `w = o · max(0.15, 0.5^(ageDays / 365))` (one-year half-life, floored so a lapsed season does not erase the record).

**Skill (1-100)**: sort entries by `e` descending, accumulate `w`; `skill` = the `e` of the first entry at which the cumulative weight reaches 2.0, i.e. the highest difficulty backed by at least two weighted confident runs. If the total weight is below 2.0, `skill = round(0.9 · max e)` and the UI labels it *provisional*. Store the daily series (walk-forward recompute using only entries up to each date) for the progression chart.

**Comfort zone** (secondary stat): weighted 75th percentile of `e` over clean runs in the last 60 days, to show where the skier actually spends time versus their ceiling.

**Next challenges**: trails with no clean log whose rating is in `[skill + 3, skill + 12]`, sorted by rating ascending then by lift pod (prefer pods the user rode recently); hide `gated` trails until `skill ≥ 58` and `hike_to` trails until `skill ≥ 65`; show up to 8. **Stretch**: `[skill + 13, skill + 20]`, shown collapsed. **Consolidate**: not-yet-skied trails in `[skill − 5, skill + 2]`, to widen the base. The bucket list is user-curated; a trail is crossed off on the first clean log, and the 3D map shows a struck-through label.

## 9. Pipeline definitions the formula depends on

The constants in section 3 were tuned to statistics computed this way; the pipeline must match:

1. Elevation source: AWS Terrain Tiles terrarium at z=15 (verified), bilinear sampling; fall back to USGS EPQS (1 m 3DEP, one point per call) for spot checks, Open-Meteo (90 m, rate-limited) last.
2. Orient each OSM way downhill (swap if the last vertex is higher than the first). Resample at 10 m horizontal spacing by linear interpolation of elevation along the line.
3. Window grades: for window length W metres use k = W/10 samples; grade = (z[i] − z[i+k]) / (s[i+k] − s[i]) · 100; `max_grade_pct` = max over W = 50; `sustained_grade_pct` = max over W = 150; `p90_grade` = 90th percentile over W = 30. Ways shorter than 20 m are skipped. For a way shorter than the window, use the whole way.
4. Merge ways by exact name: sum lengths and drops; take the max of the window stats across ways; `avg_grade_pct` = total drop / total inclined length · 100.
5. Keep `osm_difficulty`, `grooming` and `gladed` from the tags of any of the merged ways (they are consistent at Heavenly).
6. Aspect: bearing of the vector from the top vertex to the bottom vertex of the longest way, bucketed to 8 compass points.
7. Expect DEM artefacts on short greens near buildings and roads; the formula's ramps absorb them, but a 50 m max above 40 % on an `easy` trail should be logged as a warning.

## Appendix A: computed ratings for all 126 named trails (v1 constants, terrain-tile stats)

Columns: rating, band, OSM difficulty, sustained %, max %, vertical m, then the term breakdown (base / max / fatigue / terrain / hazards -> raw).

| Rating | Band | Trail | OSM | S % | M % | Vert m | base / max / fat / terr / haz -> raw |
|---|---|---|---|---|---|---|---|
| 97 | Extreme | The Fingers | expert | 91.4 | 100.6 | 260 | 81.4 / 3.2 / 5.2 / 8.0 / 18.0 -> 107.9 |
| 96 | Extreme | Ramarah's | expert | 88.2 | 95.1 | 173 | 80.3 / 2.4 / 3.5 / 8.0 / 17.0 -> 105.6 |
| 96 | Extreme | Pipeline | expert | 76.5 | 84.8 | 223 | 74.9 / 2.9 / 4.5 / 8.0 / 16.0 -> 103.1 |
| 95 | Extreme | Snake Eyes | expert | 72.8 | 79.0 | 185 | 72.7 / 2.2 / 3.7 / 8.0 / 17.0 -> 101.8 |
| 94 | Extreme | Under the Gun | expert | 70.0 | 71.0 | 149 | 71.0 / 0.3 / 3.0 / 8.0 / 16.0 -> 98.4 |
| 93 | Extreme | The "Y" | expert | 72.2 | 78.4 | 131 | 72.3 / 2.2 / 2.6 / 8.0 / 12.0 -> 97.1 |
| 93 | Extreme | Stateline | expert | 69.5 | 74.8 | 141 | 70.6 / 1.8 / 2.8 / 8.0 / 13.0 -> 96.3 |
| 92 | Extreme | Bill's | expert | 74.8 | 78.5 | 239 | 73.9 / 1.3 / 4.8 / 8.0 / 6.0 -> 94.0 |
| 90 | Extreme | Bobs Boulevard | expert | 66.4 | 71.1 | 231 | 68.1 / 1.6 / 4.6 / 8.0 / 9.0 -> 91.4 |
| 90 | Extreme | Outer Limits | expert | 65.6 | 69.7 | 235 | 67.5 / 1.4 / 4.7 / 8.0 / 9.0 -> 90.6 |
| 89 | Extreme | Hemlock | expert | 68.5 | 76.1 | 152 | 69.8 / 2.7 / 3.0 / 8.0 / 6.0 -> 89.5 |
| 89 | Extreme | Boundry Chutes | expert | 60.7 | 63.1 | 97 | 63.6 / 0.8 / 1.9 / 8.0 / 16.0 -> 90.3 |
| 88 | Extreme | Sweetwater | expert | 65.2 | 69.2 | 167 | 67.2 / 1.4 / 3.3 / 8.0 / 9.0 -> 88.9 |
| 88 | Extreme | Pac-Man | expert | 61.7 | 77.2 | 103 | 64.4 / 4.2 / 2.1 / 8.0 / 10.0 -> 88.6 |
| 88 | Extreme | Widow Maker | expert | 57.0 | 64.6 | 175 | 60.0 / 2.6 / 3.5 / 8.0 / 14.0 -> 88.2 |
| 87 | Extreme | Ernie's | expert | 69.8 | 74.8 | 56 | 70.8 / 1.8 / 1.1 / 8.0 / 6.0 -> 87.7 |
| 86 | Extreme | Hogsback | advanced | 62.7 | 63.2 | 468 | 65.2 / 0.2 / 9.4 / 8.0 / 5.0 -> 86.3 |
| 86 | Extreme | Milky Way Bowl | advanced | 59.1 | 63.1 | 195 | 62.1 / 1.4 / 3.9 / 10.9 / 8.0 -> 85.7 |
| 85 | Expert | North 40 | expert | 63.9 | 70.9 | 110 | 66.1 / 2.5 / 2.2 / 8.0 / 6.0 -> 84.8 |
| 84 | Expert | Hully Gully | expert | 55.1 | 57.5 | 218 | 58.1 / 0.8 / 4.4 / 8.0 / 13.0 -> 84.3 |
| 83 | Expert | East Bowl Woods | advanced | 65.8 | 66.5 | 304 | 67.6 / 0.2 / 6.1 / 8.0 / 1.0 -> 83.0 |
| 81 | Expert | Pinenuts | expert | 60.2 | 62.0 | 166 | 63.2 / 0.6 / 3.3 / 8.0 / 6.0 -> 81.1 |
| 80 | Expert | Gunbarrel | expert | 58.9 | 62.3 | 283 | 61.9 / 1.2 / 5.7 / 10.9 / 0.0 -> 79.7 |
| 80 | Expert | Southern Comfort | expert | 58.4 | 62.1 | 184 | 61.4 / 1.3 / 3.7 / 8.0 / 6.0 -> 80.4 |
| 77 | Expert | Meadows | expert | 50.5 | 62.2 | 106 | 53.5 / 4.1 / 2.1 / 8.0 / 9.0 -> 76.7 |
| 75 | Expert | Backstroke | expert | 56.8 | 57.3 | 273 | 59.8 / 0.2 / 5.5 / 8.0 / 2.0 -> 75.4 |
| 74 | Expert | Pistol | advanced | 55.3 | 57.2 | 200 | 58.3 / 0.7 / 4.0 / 10.5 / 1.0 -> 74.5 |
| 74 | Expert | Promised Land | expert | 51.8 | 61.7 | 87 | 54.8 / 3.5 / 1.7 / 8.0 / 6.0 -> 74.0 |
| 71 | Expert | East Bowl | expert | 53.6 | 54.0 | 194 | 56.6 / 0.2 / 3.9 / 10.4 / 0.0 -> 71.0 |
| 71 | Expert | Express Line | advanced | 48.4 | 55.7 | 357 | 51.0 / 2.6 / 7.1 / 9.8 / 0.0 -> 70.6 |
| 69 | Advanced | Advanced Round-a-Bout | advanced | 53.0 | 58.1 | 160 | 56.0 / 1.8 / 3.2 / 8.0 / 0.0 -> 69.0 |
| 69 | Advanced | Pinnacles | advanced | 45.5 | 47.7 | 619 | 47.6 / 0.8 / 10.0 / 8.0 / 3.0 -> 69.4 |
| 67 | Advanced | Upper Tamarack Woods | expert | 50.6 | 50.8 | 192 | 53.6 / 0.1 / 3.8 / 8.0 / 1.0 -> 66.5 |
| 67 | Advanced | The Face | expert | 50.5 | 50.7 | 190 | 53.5 / 0.1 / 3.8 / 10.0 / 0.0 -> 67.4 |
| 67 | Advanced | West Bowl | advanced | 47.1 | 54.1 | 195 | 49.5 / 2.5 / 3.9 / 9.7 / 1.0 -> 66.5 |
| 66 | Advanced | Bohemian Grove | advanced | 48.1 | 52.0 | 298 | 50.7 / 1.4 / 6.0 / 8.0 / 0.0 -> 66.0 |
| 64 | Advanced | North Bowl | advanced | 44.9 | 53.3 | 257 | 46.8 / 2.9 / 5.1 / 9.5 / 0.0 -> 64.4 |
| 64 | Advanced | Ellie's | advanced | 44.2 | 46.9 | 380 | 45.9 / 0.9 / 7.6 / 9.4 / 0.0 -> 63.8 |
| 62 | Advanced | Fall Line | advanced | 48.6 | 50.8 | 103 | 51.4 / 0.8 / 2.1 / 8.0 / 0.0 -> 62.2 |
| 62 | Advanced | Double Down | advanced | 46.7 | 49.0 | 101 | 49.1 / 0.8 / 2.0 / 9.7 / 0.0 -> 61.5 |
| 62 | Advanced | Milky Way | advanced | 44.2 | 55.8 | 114 | 45.9 / 4.1 / 2.3 / 9.4 / 0.0 -> 61.7 |
| 61 | Advanced | Powder Line | advanced | 47.6 | 48.8 | 104 | 50.1 / 0.4 / 2.1 / 8.0 / 0.0 -> 60.7 |
| 61 | Advanced | Waterfall | advanced | 45.9 | 47.3 | 119 | 48.1 / 0.5 / 2.4 / 9.6 / 0.0 -> 60.5 |
| 60 | Advanced | Aries Woods | advanced | 45.3 | 48.9 | 188 | 47.3 / 1.3 / 3.8 / 8.0 / 0.0 -> 60.4 |
| 60 | Advanced | On Hold | expert | 39.2 | 42.7 | 188 | 38.7 / 1.2 / 3.8 / 8.0 / 5.0 -> 60.0 |
| 60 | Advanced | Mott Canyon Trail | advanced | 19.0 | 19.8 | 121 | 9.0 / 0.0 / 0.0 / 0.0 / 9.0 -> 60.0 |
| 60 | Advanced | Rim Trail | expert | 16.5 | 26.9 | 59 | 6.5 / 0.0 / 0.0 / 8.0 / 12.0 -> 60.0 |
| 59 | Advanced | Tamarack Woods | advanced | 45.0 | 48.0 | 157 | 47.0 / 1.1 / 3.1 / 8.0 / 0.0 -> 59.1 |
| 59 | Advanced | Little Dipper | advanced | 43.3 | 45.6 | 202 | 44.7 / 0.8 / 4.0 / 9.3 / 0.0 -> 58.8 |
| 58 | Advanced | Sky Canyon | advanced | 43.4 | 47.3 | 139 | 44.8 / 1.4 / 2.8 / 9.3 / 0.0 -> 58.3 |
| 58 | Advanced | Dipper Bowl | advanced | 43.3 | 47.3 | 153 | 44.6 / 1.4 / 3.1 / 9.3 / 0.0 -> 58.4 |
| 57 | Advanced | Powderbowl Woods | advanced | 44.3 | 45.1 | 134 | 46.0 / 0.3 / 2.7 / 8.0 / 0.0 -> 57.0 |
| 57 | Advanced | The Burn | advanced | 43.4 | 44.9 | 187 | 44.7 / 0.5 / 3.7 / 8.0 / 0.0 -> 57.0 |
| 57 | Advanced | Ski Ways Glades | advanced | 39.4 | 49.8 | 338 | 39.0 / 3.6 / 6.8 / 8.0 / 0.0 -> 57.4 |
| 56 | Advanced | The Pines | intermediate | 43.1 | 44.1 | 140 | 44.4 / 0.4 / 2.8 / 8.0 / 0.0 -> 55.5 |
| 55 | Intermediate | Cepheus | advanced | 40.3 | 54.7 | 143 | 40.4 / 4.2 / 2.9 / 8.0 / 0.0 -> 55.4 |
| 54 | Intermediate | Ponderosa | intermediate | 45.1 | 50.4 | 237 | 47.1 / 1.9 / 4.7 / 0.0 / 0.0 -> 53.7 |
| 52 | Intermediate | Mineshaft | intermediate | 45.7 | 46.6 | 192 | 47.9 / 0.3 / 3.8 / 0.0 / 0.0 -> 52.0 |
| 52 | Intermediate | Stagecoach Woods | advanced | 40.8 | 43.4 | 118 | 41.1 / 0.9 / 2.4 / 8.0 / 0.0 -> 52.4 |
| 52 | Intermediate | Dipper Line | advanced | 35.4 | 39.2 | 76 | 32.7 / 1.3 / 1.5 / 16.5 / 0.0 -> 52.1 |
| 51 | Intermediate | Nevada Woods | advanced | 38.3 | 39.5 | 283 | 37.3 / 0.4 / 5.7 / 8.0 / 0.0 -> 51.4 |
| 51 | Intermediate | Meteor | intermediate | 38.1 | 42.5 | 162 | 36.9 / 1.5 / 3.2 / 8.8 / 0.0 -> 50.5 |
| 50 | Intermediate | Comstock | intermediate | 41.2 | 46.9 | 315 | 41.7 / 2.0 / 6.3 / 0.0 / 0.0 -> 50.0 |
| 50 | Intermediate | Scorpion Woods | advanced | 37.9 | 39.6 | 246 | 36.6 / 0.6 / 4.9 / 8.0 / 0.0 -> 50.1 |
| 49 | Intermediate | Emily's Run | intermediate | 42.7 | 46.7 | 212 | 43.8 / 1.4 / 4.2 / 0.0 / 0.0 -> 49.4 |
| 48 | Intermediate | Stage Line | intermediate | 37.0 | 37.0 | 207 | 35.2 / 0.0 / 4.1 / 8.7 / 0.0 -> 48.1 |
| 48 | Intermediate | Maggie's Canyon | advanced | 36.0 | 44.0 | 166 | 33.5 / 2.8 / 3.3 / 8.0 / 0.0 -> 47.6 |
| 46 | Intermediate | Powderbowl Run | intermediate | 41.9 | 43.0 | 127 | 42.6 / 0.4 / 2.5 / 0.0 / 0.0 -> 45.5 |
| 46 | Intermediate | Stagecoach | intermediate | 41.3 | 42.5 | 203 | 41.8 / 0.4 / 4.1 / 0.0 / 0.0 -> 46.3 |
| 45 | Intermediate | Dipper Woods | advanced | 35.6 | 35.6 | 188 | 33.0 / 0.0 / 3.8 / 8.0 / 0.0 -> 44.9 |
| 44 | Intermediate | Upper Bonanza | intermediate | 36.0 | 40.6 | 63 | 33.6 / 1.6 / 1.3 / 8.0 / 0.0 -> 44.5 |
| 44 | Intermediate | Galaxy Woods | intermediate | 34.3 | 40.4 | 156 | 30.9 / 2.1 / 3.1 / 8.0 / 0.0 -> 44.1 |
| 42 | Intermediate | Boulder Chute | advanced | 33.7 | 37.0 | 153 | 29.9 / 1.1 / 3.1 / 2.0 / 3.0 -> 42.1 |
| 41 | Intermediate | High Five | intermediate | 35.2 | 39.4 | 335 | 32.4 / 1.5 / 6.7 / 0.0 / 0.0 -> 40.5 |
| 41 | Intermediate | Cascade | intermediate | 33.0 | 35.6 | 156 | 28.8 / 0.9 / 3.1 / 8.3 / 0.0 -> 41.1 |
| 40 | Easy Int | Ridge Bowl | advanced | 35.2 | 37.8 | 102 | 32.3 / 0.9 / 2.0 / 0.0 / 0.0 -> 40.1 |
| 40 | Easy Int | Liz's | intermediate | 34.7 | 37.5 | 383 | 31.5 / 1.0 / 7.7 / 0.0 / 0.0 -> 40.1 |
| 39 | Easy Int | Bonanza | intermediate | 36.4 | 42.4 | 130 | 34.3 / 2.1 / 2.6 / 0.0 / 0.0 -> 38.9 |
| 39 | Easy Int | Big Dipper | intermediate | 34.6 | 37.1 | 355 | 31.3 / 0.9 / 7.1 / 0.0 / 0.0 -> 39.3 |
| 36 | Easy Int | Nova | intermediate | 31.0 | 32.0 | 99 | 25.7 / 0.3 / 2.0 / 8.1 / 0.0 -> 36.1 |
| 36 | Easy Int | Olympic Downhill | intermediate | 30.2 | 35.3 | 473 | 24.3 / 1.8 / 9.5 / 0.0 / 0.0 -> 35.6 |
| 33 | Easy Int | 49'er | intermediate | 33.8 | 36.5 | 108 | 30.1 / 0.9 / 2.2 / 0.0 / 0.0 -> 33.2 |
| 33 | Easy Int | Canyonland | intermediate | 30.8 | 33.7 | 312 | 25.3 / 1.0 / 6.2 / 0.0 / 0.0 -> 32.5 |
| 32 | Easy Int | Comet | intermediate | 30.7 | 34.6 | 268 | 25.1 / 1.4 / 5.4 / 0.0 / 0.0 -> 31.9 |
| 32 | Easy Int | Ridge Run | intermediate | 29.4 | 32.5 | 433 | 23.1 / 1.0 / 8.4 / 0.0 / 0.0 -> 32.5 |
| 32 | Easy Int | Advanced California Trail | intermediate | 29.1 | 29.1 | 84 | 22.5 / 0.0 / 1.6 / 8.0 / 0.0 -> 32.1 |
| 31 | Easy Int | California Trail | intermediate | 29.4 | 32.2 | 369 | 23.1 / 0.9 / 7.2 / 0.0 / 0.0 -> 31.2 |
| 30 | Easy Int | World Cup | intermediate | 32.5 | 33.8 | 99 | 28.0 / 0.4 / 2.0 / 0.0 / 0.0 -> 30.4 |
| 30 | Easy Int | Cloud 9 | intermediate | 30.7 | 34.1 | 179 | 25.1 / 1.2 / 3.6 / 0.0 / 0.0 -> 29.9 |
| 30 | Easy Int | Orion | intermediate | 29.2 | 31.2 | 337 | 22.7 / 0.6 / 6.5 / 0.0 / 0.0 -> 29.8 |
| 29 | Easy Int | Upper North Bowl | intermediate | 30.6 | 35.6 | 119 | 24.9 / 1.8 / 2.4 / 0.0 / 0.0 -> 29.0 |
| 29 | Easy Int | Ellie's Swing | advanced | 19.1 | 24.9 | 83 | 9.1 / 0.0 / 0.0 / 0.0 / 3.0 -> 28.5 |
| 26 | Easy Int | Jack's | intermediate | 28.8 | 36.2 | 106 | 22.1 / 2.3 / 2.0 / 0.0 / 0.0 -> 26.4 |
| 26 | Easy Int | Lower Stagecoach | intermediate | 28.4 | 31.5 | 200 | 21.4 / 0.9 / 3.7 / 0.0 / 0.0 -> 26.0 |
| 25 | Easy Int | $100 Saddle | intermediate | 29.7 | 30.4 | 89 | 23.5 / 0.2 / 1.7 / 0.0 / 0.0 -> 25.5 |
| 25 | Easy Int | Aries | intermediate | 28.5 | 36.2 | 74 | 21.6 / 2.3 / 1.4 / 0.0 / 0.0 -> 25.3 |
| 24 | Easy Int | Perimeter | intermediate | 26.9 | 29.9 | 239 | 19.1 / 0.7 / 4.0 / 0.0 / 0.0 -> 23.8 |
| 24 | Easy Int | Mombo | intermediate | 26.7 | 33.2 | 241 | 18.8 / 1.5 / 4.0 / 0.0 / 0.0 -> 24.4 |
| 24 | Easy Int | Galaxy | intermediate | 26.5 | 32.6 | 236 | 18.4 / 1.4 / 3.9 / 0.0 / 0.0 -> 23.7 |
| 22 | Easy Int | Upper Mombo | intermediate | 27.3 | 32.0 | 58 | 19.7 / 1.2 / 1.0 / 0.0 / 0.0 -> 21.9 |
| 18 | Beginner | Steins Way | intermediate | 25.3 | 27.2 | 110 | 16.5 / 0.4 / 1.7 / 0.0 / 0.0 -> 18.5 |
| 18 | Beginner | Enchanted Forest | easy | 24.5 | 42.7 | 36 | 15.4 / 1.9 / 0.5 / 0.0 / 0.0 -> 17.9 |
| 18 | Beginner | Sam's Dream | intermediate | 24.2 | 28.8 | 134 | 15.1 / 0.7 / 1.9 / 0.0 / 0.0 -> 17.7 |
| 18 | Beginner | Nevada Trail | intermediate | 22.9 | 31.7 | 277 | 13.5 / 0.9 / 3.6 / 0.0 / 0.0 -> 18.0 |
| 17 | Beginner | Cosmic Wave | intermediate | 24.0 | 24.2 | 144 | 14.8 / 0.0 / 2.0 / 0.0 / 0.0 -> 16.9 |
| 16 | Beginner | Boulder Bowl | easy | 23.7 | 25.1 | 131 | 14.4 / 0.2 / 1.8 / 0.0 / 0.0 -> 16.4 |
| 15 | Beginner | Groove Park | easy | 22.6 | 26.7 | 87 | 13.1 / 0.4 / 1.1 / 0.0 / 0.0 -> 14.5 |
| 15 | Beginner | Von Schmidt | intermediate | 22.4 | 28.7 | 105 | 12.8 / 0.5 / 1.3 / 0.0 / 0.0 -> 14.8 |
| 15 | Beginner | Stagecoach Return | intermediate | 20.9 | 27.3 | 41 | 11.1 / 0.2 / 0.0 / 0.0 / 3.0 -> 14.7 |
| 14 | Beginner | Sand Dunes | intermediate | 21.8 | 22.8 | 49 | 12.1 / 0.1 / 0.6 / 0.0 / 0.0 -> 13.9 |
| 14 | Beginner | Outlaw | intermediate | 21.6 | 22.7 | 99 | 12.0 / 0.1 / 1.2 / 0.0 / 0.0 -> 14.1 |
| 14 | Beginner | Tamarack Return | intermediate | 19.6 | 22.9 | 72 | 9.6 / 0.0 / 0.0 / 0.0 / 3.0 -> 13.8 |
| 13 | Beginner | Orion's Belt | intermediate | 20.0 | 23.2 | 38 | 10.0 / 0.0 / 0.4 / 0.0 / 0.0 -> 12.7 |
| 13 | Beginner | Round-a-Bout | intermediate | 16.1 | 26.0 | 320 | 6.1 / 0.0 / 1.9 / 0.0 / 3.0 -> 13.0 |
| 11 | Beginner | Maggie's | easy | 19.2 | 20.6 | 231 | 9.3 / 0.0 / 2.1 / 0.0 / 0.0 -> 11.4 |
| 11 | Beginner | Upper Perimeter | intermediate | 16.9 | 22.1 | 51 | 6.9 / 0.0 / 0.4 / 0.0 / 0.0 -> 11.1 |
| 11 | Beginner | Crossover | intermediate | 14.7 | 19.9 | 95 | 4.8 / 0.0 / 0.0 / 0.0 / 3.0 -> 11.4 |
| 11 | Beginner | Upper Dipper Return | intermediate | 14.4 | 16.2 | 50 | 4.7 / 0.0 / 0.0 / 0.0 / 3.0 -> 11.3 |
| 11 | Beginner | Skyline Trail | intermediate | 13.1 | 20.1 | 124 | 3.9 / 0.0 / 0.0 / 0.0 / 3.0 -> 10.9 |
| 11 | Beginner | Swing Trail | intermediate | 11.8 | 13.2 | 39 | 3.1 / 0.0 / 0.0 / 0.0 / 3.0 -> 10.5 |
| 10 | Beginner | Pepi's | intermediate | 10.5 | 15.7 | 71 | 2.3 / 0.0 / 0.0 / 0.0 / 3.0 -> 10.2 |
| 10 | Beginner | Lower Dipper Return | intermediate | 8.8 | 9.5 | 26 | 1.8 / 0.0 / 0.0 / 0.0 / 3.0 -> 9.9 |
| 10 | Beginner | Silver Spur | intermediate | 8.6 | 14.0 | 16 | 1.7 / 0.0 / 0.0 / 0.0 / 3.0 -> 9.9 |
| 9 | Beginner | Easy Street | easy | 18.5 | 21.5 | 42 | 8.5 / 0.0 / 0.4 / 0.0 / 0.0 -> 8.9 |
| 7 | Beginner | Poma Trail | easy | 17.0 | 26.8 | 56 | 7.0 / 0.0 / 0.4 / 0.0 / 0.0 -> 7.4 |
| 6 | Beginner | Patsy's | easy | 15.5 | 24.7 | 68 | 5.5 / 0.0 / 0.4 / 0.0 / 0.0 -> 5.8 |

## Appendix B: Python reference implementation (used for calibration)

```python
import math
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
```

## Appendix C: sources

- Wikipedia, "Piste" - https://en.wikipedia.org/wiki/Piste
- SnowBrains, "Inconsistencies in Classification of Ski Slope Difficulty Ratings" - https://snowbrains.com/inconsistencies-in-classification-of-ski-slope-difficulty-ratings
- PeakRankings, "Green vs. Blue vs. Black" - https://www.peakrankings.com/content/green-vs-blue-vs-black-understanding-levels-of-ski-resort-terrain
- OSM wiki, Key:piste:difficulty - https://wiki.openstreetmap.org/wiki/Key:piste:difficulty
- openskidata-format, Run.ts (RunDifficulty, RunGrooming, elevation profile) - https://github.com/russellporter/openskidata-format
- SteepSeeker methodology - https://steepseeker.com/about ; discussion https://www.skitalk.com/threads/steep-seeker-ski-map-site.39106/
- DCSki forum, "Unofficial Steepest US Runs" (Gunbarrel 31.6°) - https://www.dcski.com/forum/37293
- mahsu/ski-resort-analysis - https://github.com/mahsu/ski-resort-analysis
- Heavenly mountain info - https://www.skiheavenly.com/the-mountain/about-the-mountain/mountain-info.aspx
- Heavenly trail map page - https://www.skiheavenly.com/the-mountain/about-the-mountain/trail-map.aspx
- Heavenly signature experience checklist - https://www.skiheavenly.com/explore-the-resort/experience-heavenly/experience-checklist.aspx
- skiresort.com Heavenly slope offering - https://www.skiresort.com/en/ski-resort/heavenly/slope-offering/
- Visit Lake Tahoe, "9 Iconic Ski Trails" - https://visitlaketahoe.com/explore/ski-snowboard-blog/articles/9-iconic-ski-trails-to-hit-this-winter-at-tahoe-south-ski-resorts/
- Don's Notes, Gunbarrel - https://donsnotes.com/sports/ski_gunbarrel.html
- World Snowboard Guide, Heavenly riding guide - https://www.worldsnowboardguide.com/usa/heavenly/heavenly-riding-guide.html
- xpatmatt, Heavenly Micro Guide - https://xpatmatt.com/?p=9039
- DCSki, Heavenly firsthand report (Olympic) - https://www.dcski.com/articles/1677
- ski.com, Heavenly expert skiing (rate-limited during research; quoted from search snippets) - https://www.ski.com/heavenly-expert-skiing
- FirstTracks!! Online trip reports: 2008-01 MLK - https://firsttracksonline.com/boards/threads/heavenly-ca-and-nv-1-21-2008-mlk.6281 ; 2017-04 - https://firsttracksonline.com/boards/threads/heavenly-ca-and-nv-4-5-2017.12386 ; 2019-03 - https://www.firsttracksonline.com/boards/threads/heavenly-ca-and-nv-march-15-16-2019-and-long-trip-summary.12855/latest
- SkiTalk: Rose and Heavenly Feb 11-12 - https://www.skitalk.com/threads/rose-and-heavenly-feb-11-12.14588/ ; 2022-23 Tahoe conditions thread posts 1443-1455 - https://www.skitalk.com/threads/2022-2023-tahoe-ski-resorts-conditions-meetups.28082/post-839451
- Reddit r/Heavenly, "Mott Canyon first timer" (via search snippet only) - https://www.reddit.com/r/Heavenly/comments/1b2ihkl/mott_canyon_first_timer/
- Terrain: AWS Terrain Tiles (terrarium) - https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png ; USGS EPQS - https://epqs.nationalmap.gov/v1/json ; Open-Meteo elevation - https://api.open-meteo.com/v1/elevation
