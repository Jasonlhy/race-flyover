#!/usr/bin/env python3
"""
Builds the bundled course files in Resources/Courses/*.json.

Source geometry and aid-station waypoints come from the community collection at
https://github.com/distanzrunning/gpx (GeoJSON exports of race course maps).
That repository does not state a licence, so the generated files are meant for
personal use. Swap in an official GPX from your race organiser via the
screensaver's Options sheet whenever you have one.

For each course the script:
  * downloads the GeoJSON (cached in build/src),
  * resamples the line every RESAMPLE_M metres, keeping elevation,
  * applies bridge corrections where the source elevation follows the water
    (terrain models read the river, not the deck),
  * turns aid-station waypoints into official-distance stations, classifying
    each one as fluid, fuel, or both.

Usage:
    python3 tools/build_courses.py              # build every course
    python3 tools/build_courses.py berlin nyc   # build some
"""

import json
import math
import os
import re
import sys
import urllib.parse
import urllib.request
import time

SOURCE = "https://raw.githubusercontent.com/distanzrunning/gpx/main/"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "build", "src")
OUT_DIR = os.path.join(HERE, "..", "Resources", "Courses")
RESAMPLE_M = 25.0
MARATHON_KM = 42.195
MI = 1.609344

COURSES = [
    # World Marathon Majors
    {"id": "boston", "landmarks": ['Wellesley College', 'Boston College', 'Citgo Sign', 'Fenway Park', 'Boston Public Library', 'Trinity Church Boston'], "country": "US", "file": "boston_marathon.json", "name": "Boston Marathon",
     "city": "Hopkinton → Boston, USA", "month": "April", "major": True},
    {"id": "london", "landmarks": ['Cutty Sark', 'Tower Bridge', 'One Canada Square', 'Tower of London', 'London Eye', 'Elizabeth Tower', 'Buckingham Palace'], "country": "GB", "file": "london_marathon_1.json", "name": "London Marathon",
     "city": "Greenwich → The Mall, UK", "month": "April", "major": True},
    {"id": "berlin", "landmarks": ['Victory Column', 'Reichstag Building', 'Rathaus Schöneberg', 'Kaiser Wilhelm Memorial Church', 'KaDeWe', 'Potsdamer Platz', 'Gendarmenmarkt', 'Brandenburg Gate'], "country": "DE", "file": "berlin_marathon.json", "name": "Berlin Marathon",
     "city": "Berlin, Germany", "month": "September", "major": True},
    {"id": "chicago", "landmarks": ['Buckingham Fountain', 'Lincoln Park Zoo', 'Willis Tower', 'United Center', 'Chinatown Gate Chicago', 'Art Institute of Chicago'], "country": "US", "file": "chicargo_marathon.json", "name": "Chicago Marathon",
     "city": "Chicago, USA", "month": "October", "major": True},
    {"id": "nyc", "landmarks": ['Verrazzano-Narrows Bridge', 'Barclays Center', 'Pulaski Bridge', 'Queensboro Bridge', 'Willis Avenue Bridge', 'Solomon R. Guggenheim Museum', 'Columbus Circle', 'Tavern on the Green'], "country": "US", "file": "new_york_city_marathon.json", "name": "New York City Marathon",
     "city": "Staten Island → Central Park, USA", "month": "November", "major": True,
     # (source km start, source km end, deck peak metres)
     "bridges": [(0.35, 2.65, 69), (21.55, 22.45, 16), (23.85, 25.62, 40)],
     # The source lists only some fluid stations (all on mile marks); NYRR runs
     # fluids at every mile from mile 3, with gels at mile 18.
     "stations_override": [{"km": m * MI, "fluid": True, "fuel": False, "label": "Water + Gatorade"}
                           for m in range(3, 27)]
                          + [{"km": 18 * MI + 0.05, "fluid": False, "fuel": True, "label": "Energy gels"}]},
    {"id": "tokyo", "landmarks": ['Tokyo Metropolitan Government Building', 'Kaminarimon', 'Ryogoku Kokugikan', 'Tomioka Hachimangu', 'Nihonbashi Bridge', 'Ginza Wako', 'Zojoji Temple', 'Tokyo Station'], "country": "JP", "file": "tokyo_marathon_geo.json", "name": "Tokyo Marathon",
     "city": "Tokyo, Japan", "month": "March", "major": True},
    {"id": "sydney", "landmarks": ['Sydney Harbour Bridge', 'Sydney Town Hall', 'Centennial Park', 'Hyde Park Sydney', 'Art Gallery of New South Wales', "Mrs Macquarie's Chair", 'Sydney Opera House'], "country": "AU", "file": "sydney_marathon.json", "name": "Sydney Marathon",
     "city": "North Sydney → Opera House, Australia", "month": "August", "major": True},
    # Other big-city marathons
    {"id": "amsterdam", "country": "NL", "file": "amsterdam_marathon.json", "name": "Amsterdam Marathon",
     "city": "Amsterdam, Netherlands", "month": "October"},
    {"id": "valencia", "country": "ES", "file": "valencia_marathon.json", "name": "Valencia Marathon",
     "city": "Valencia, Spain", "month": "December"},
    {"id": "paris", "country": "FR", "file": "paris-marathon.json", "name": "Paris Marathon",
     "city": "Paris, France", "month": "April"},
    {"id": "losangeles", "country": "US", "file": "los_angeles_marathon.json", "name": "Los Angeles Marathon",
     "city": "Dodger Stadium → Century City, USA", "month": "March"},
    {"id": "houston", "country": "US", "file": "houston_marathon.json", "name": "Houston Marathon",
     "city": "Houston, USA", "month": "January"},
    {"id": "mexicocity", "country": "MX", "file": "mexico_city_marathon.json", "name": "Mexico City Marathon",
     "city": "Mexico City, Mexico", "month": "August"},
    {"id": "osaka", "country": "JP", "file": "osaka_marathon.json", "name": "Osaka Marathon",
     "city": "Osaka, Japan", "month": "February"},
    {"id": "singapore", "country": "SG", "file": "singapore_marathon.json", "name": "Singapore Marathon",
     "city": "Singapore", "month": "December"},
    {"id": "taipei", "country": "TW", "file": "taipei_marathon.json", "name": "Taipei Marathon",
     "city": "Taipei, Taiwan", "month": "December"},
    {"id": "kyoto", "landmarks": ['Togetsukyo Bridge', 'Ninna-ji', 'Ryoan-ji', 'Kamigamo Shrine', 'Kyoto Botanical Gardens', 'Kyoto City Hall', 'Heian Shrine'], "country": "JP", "name": "Kyoto Marathon",
     "file": "kyoto_marathon.gpx",
     "url": "https://www.goandrace.com/gpx/2025/02/16/gpx_20250216_id10116_race1_20250111195530.gpx",
     "city": "Nishikyogoku → Heian-jingu Shrine, Japan", "month": "February",
     # Official 2025 participant guide: 14 water stations, sports drink at
     # alternate stations, food at stations 5–11 and 13.
     "stations_override": [
         {"km": km, "fluid": True, "fuel": bool(food),
          "label": ("Water + sports drink" if sports else "Water") + (f" · {food}" if food else "")}
         for km, sports, food in [
             (4.5, True, ""), (7.9, False, ""), (10.6, True, ""), (12.5, False, ""),
             (15.3, True, "Bananas, salt tablets"),
             (17.6, False, "Rice crackers, kombu, matcha biscuits"),
             (20.6, True, "Strawberry bread, senbei, cherry tomatoes"),
             (23.1, False, "Salt tablets, sweets"),
             (26.5, True, "Kyobaum cake, Ramune candy"),
             (29.5, False, "Bananas, senbei"),
             (32.2, True, "Strawberries, cherry tomatoes, rice crackers"),
             (35.1, False, ""),
             (37.2, True, "Kyobaum matcha cake"),
             (40.8, False, ""),
         ]]},
    {"id": "shanghai", "country": "CN", "file": "shanghai_marathon.json", "name": "Shanghai Marathon",
     "city": "Shanghai, China", "month": "November"},
]

FUEL_WORDS = ("gel", "maurten", "gu ", "gu,", "shot", "banana", "food", "bread", "candy",
              "chocolate", "orange", "bean", "plum", "fruit", "energy")
FLUID_WORDS = ("water", "gatorade", "drink", "electrolyte", "electrolit", "fluid",
               "refreshment", "isotonic", "tea", "sports drink", "aid station", "food")
SKIP_WORDS = ("cheer", "biofreeze", "halfway", "finish", "start", "medical tent", "toilet")

# ---------------------------------------------------------------------------


def haversine(a, b):
    r = 6371008.8
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def fetch(name, url=None):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        req = urllib.request.Request(url or SOURCE + name, headers={"User-Agent": "Mozilla/5.0 RaceFlyover-course-builder/1.0"})
        with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
            f.write(r.read())
    with open(path) as f:
        return f.read() if name.endswith(".gpx") else json.load(f)


def load_gpx(text):
    """Track (or route) points with elevation; waypoints are ignored."""
    pts = []
    for m in re.finditer(r'<(?:trkpt|rtept)\s+lat="([-\d.]+)"\s+lon="([-\d.]+)"\s*>(.*?)</(?:trkpt|rtept)>', text, re.S):
        ele = re.search(r"<ele>([-\d.]+)</ele>", m.group(3))
        pts.append((float(m.group(1)), float(m.group(2)), float(ele.group(1)) if ele else None))
    dedup = [pts[0]]
    for p in pts[1:]:
        if haversine(p, dedup[-1]) > 0.5:
            dedup.append(p)
    return dedup, []


def load(course):
    if course["file"].endswith(".gpx"):
        return load_gpx(fetch(course["file"], course.get("url")))
    data = fetch(course["file"])
    feats = data["features"] if "features" in data else [data]
    line, waypoints = [], []
    for ft in feats:
        g = ft["geometry"]
        if g["type"] == "LineString":
            line.extend(g["coordinates"])
        elif g["type"] == "MultiLineString":
            for part in g["coordinates"]:
                line.extend(part)
        elif g["type"] == "Point":
            waypoints.append((g["coordinates"], ft.get("properties", {})))
    pts = [(c[1], c[0], c[2] if len(c) > 2 and c[2] is not None else None) for c in line]
    dedup = [pts[0]]
    for p in pts[1:]:
        if haversine(p, dedup[-1]) > 0.5:
            dedup.append(p)
    return dedup, waypoints


def cumulative(pts):
    d = [0.0]
    for a, b in zip(pts, pts[1:]):
        d.append(d[-1] + haversine(a, b))
    return d


def resample(pts, step):
    dist = cumulative(pts)
    total = dist[-1]
    out, j, s = [], 0, 0.0
    while s < total:
        while dist[j + 1] < s:
            j += 1
        seg = dist[j + 1] - dist[j]
        t = 0 if seg == 0 else (s - dist[j]) / seg
        a, b = pts[j], pts[j + 1]
        ele = None
        if a[2] is not None and b[2] is not None:
            ele = a[2] + (b[2] - a[2]) * t
        out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, ele))
        s += step
    out.append(pts[-1])
    return out, total


def smooth(values, radius):
    out = []
    for i in range(len(values)):
        lo, hi = max(0, i - radius), min(len(values), i + radius + 1)
        out.append(sum(values[lo:hi]) / (hi - lo))
    return out


def apply_bridges(eles, bridges):
    for start_km, end_km, peak in bridges:
        a = int(start_km * 1000 / RESAMPLE_M)
        b = min(len(eles) - 1, int(end_km * 1000 / RESAMPLE_M))
        e0, e1 = eles[a], eles[b]
        lift = peak - (e0 + e1) / 2
        for k in range(a, b + 1):
            t = (k - a) / max(1, b - a)
            eles[k] = e0 + (e1 - e0) * t + lift * math.sin(math.pi * t)


def stated_distance(props):
    """Official distance (km) written on the waypoint, if any."""
    if isinstance(props.get("distance"), (int, float)):
        return float(props["distance"])
    name = props.get("name", "")
    m = re.search(r"mile\s*([\d.]+)", name, re.I)
    if m:
        return float(m.group(1)) * MI
    m = re.search(r"([\d.]+)\s*km", name, re.I)
    if m:
        return float(m.group(1))
    return None


def classify(props):
    name = props.get("name", "") or ""
    desc = props.get("desc", "") or props.get("services", "") or ""
    text = f" {name} {desc} ".lower()
    if any(w in text for w in SKIP_WORDS) and not any(w in text for w in ("water", "gel", "aid")):
        return None
    fuel = any(w in text for w in FUEL_WORDS)
    fluid = any(w in text for w in FLUID_WORDS)
    if not (fuel or fluid):
        return None
    label = desc.strip() if desc.strip() and desc.strip() != name.strip() else name.strip()
    label = re.sub(r"\s*&\s*First Aid", "", label)
    if label == "Food":
        label = "Food + drinks"
    label = re.sub(r"^\d+(\.\d+)?\s*km\s+", "", label)
    label = label.replace(", and ", ", ").replace(" and ", ", ")
    return {"fluid": fluid, "fuel": fuel, "label": label}


def project(waypoint, pts, dist, after_m):
    """Distance along the line of the closest point at or beyond after_m."""
    best, best_d = None, float("inf")
    for i, p in enumerate(pts):
        if dist[i] < after_m:
            continue
        d = haversine(p, waypoint)
        if d < best_d:
            best, best_d = dist[i], d
    return best, best_d


def stations_for(course, waypoints, pts, total_m):
    dist = cumulative(pts)
    out, last_m = [], 0.0
    if "stations_override" in course:
        waypoints = []
        out = [dict(s) for s in course["stations_override"]]
    for coords, props in waypoints:
        kind = classify(props)
        if not kind:
            continue
        km = stated_distance(props)
        if km is None:
            along, off = project((coords[1], coords[0]), pts, dist, max(0.0, last_m - 300))
            if along is None or off > 400:
                continue
            last_m = along
            km = along / total_m * MARATHON_KM
        else:
            last_m = km / MARATHON_KM * total_m
        out.append({"km": round(km, 3), **kind})
    out.extend(course.get("extra_stations", []))
    estimated = False
    if not out:
        estimated = True
        out = [{"km": float(k), "fluid": True, "fuel": False, "label": "Refreshments (typical)"}
               for k in range(5, 42, 5)]
    out.sort(key=lambda s: s["km"])
    merged = []
    for s in out:
        if merged and abs(merged[-1]["km"] - s["km"]) < 0.15:
            m = merged[-1]
            m["fluid"] |= s["fluid"]
            m["fuel"] |= s["fuel"]
            if s["label"] not in m["label"]:
                m["label"] += " + " + s["label"]
        else:
            merged.append({**s, "km": round(s["km"], 3)})
    return merged, estimated


DENSITY_EVERY = 12          # samples (x RESAMPLE_M) between building counts, ~300 m
DENSITY_RADIUS = 150        # metres around each sample
DENSITY_FULL = 180          # buildings within the radius that count as "fully built-up"


def building_density(course, samples):
    """How built-up the route is (0 = open, 1 = dense), every ~300 m.

    Counts OpenStreetMap buildings within DENSITY_RADIUS of points along the
    route in a single Overpass request, cached in build/src. Used by the
    screensaver's automatic tilt (steeper among buildings, lower in open areas).
    """
    cache = os.path.join(CACHE, f"{course['id']}_density.json")
    pts = samples[::DENSITY_EVERY]
    if os.path.exists(cache):
        counts = json.load(open(cache))
    else:
        body = "".join(f'way["building"](around:{DENSITY_RADIUS},{p[0]:.5f},{p[1]:.5f});out count;' for p in pts)
        data = urllib.parse.urlencode({"data": "[out:json][timeout:300];" + body}).encode()
        req = urllib.request.Request("https://overpass-api.de/api/interpreter", data=data,
                                     headers={"User-Agent": "RaceFlyover-course-builder/1.0"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=330) as r:
                    result = json.load(r)
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 2:
                    print(f"    building counts unavailable ({e}); automatic tilt disabled for this course")
                    return None
                time.sleep(10)
        counts = [int(e["tags"]["ways"]) for e in result["elements"] if e.get("type") == "count"]
        with open(cache, "w") as f:
            json.dump(counts, f)
        time.sleep(3)
    dens = [min(1.0, c / DENSITY_FULL) for c in counts]
    dens = smooth(dens, 2)
    return [round(d, 2) for d in dens]


def build(course):
    pts, waypoints = load(course)
    samples, total = resample(pts, RESAMPLE_M)
    if any(p[2] is None for p in samples):
        raise SystemExit(f"{course['id']}: source has no elevation")
    eles = [p[2] for p in samples]
    apply_bridges(eles, course.get("bridges", []))
    eles = smooth(eles, 3)
    stations, estimated = stations_for(course, waypoints, pts, cumulative(pts)[-1])
    density = building_density(course, samples)
    out = {
        "id": course["id"],
        "name": course["name"],
        "city": course["city"],
        "month": course["month"],
        "country": course["country"],
        "major": course.get("major", False),
        "distanceKm": MARATHON_KM,
        "source": course.get("url") or SOURCE.replace("raw.githubusercontent.com", "github.com").replace("/main/", ""),
        "stationsEstimated": estimated,
        "landmarks": course.get("landmarks"),
        "density": density,
        "densityStepKm": round(DENSITY_EVERY * RESAMPLE_M / total * MARATHON_KM, 4) if density else None,
        "stations": stations,
        "points": [[round(p[0], 6), round(p[1], 6), round(e, 1)] for p, e in zip(samples, eles)],
    }
    path = os.path.join(OUT_DIR, f"{course['id']}.json")
    with open(path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    fl = sum(s["fluid"] for s in stations)
    fu = sum(s["fuel"] for s in stations)
    print(f"• {course['name']:24s} {total / 1000:5.2f} km traced, {len(samples):4d} pts, "
          f"ele {min(eles):4.0f}–{max(eles):4.0f} m, {fl:2d} fluid / {fu} fuel"
          f"{'  (estimated stations)' if estimated else ''}")


def main():
    wanted = sys.argv[1:]
    os.makedirs(OUT_DIR, exist_ok=True)
    for c in COURSES:
        if not wanted or c["id"] in wanted:
            build(c)


if __name__ == "__main__":
    main()
