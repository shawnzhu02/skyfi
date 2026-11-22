"""Builds Skyfi/Resources/airports.json from the OurAirports open data.

Keeps large airports, plus medium airports with scheduled service, and their
open runways. Run from the repo root:

    python scripts/build_airports.py

The CSVs are downloaded into data/ (git-ignored) when missing.
"""

import csv
import json
import math
import os
import sys
import urllib.request

BASE = "https://davidmegginson.github.io/ourairports-data/"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "Skyfi", "Resources", "airports.json")


def fetch(name):
    path = os.path.join(DATA, name)
    if not os.path.exists(path):
        os.makedirs(DATA, exist_ok=True)
        print(f"Downloading {name}")
        urllib.request.urlretrieve(BASE + name, path)
    return path


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def heading_from_ident(ident):
    digits = "".join(c for c in (ident or "") if c.isdigit())
    if not digits:
        return None
    value = int(digits) * 10
    return float(value % 360) if 0 < value <= 360 else None


def main():
    airports = {}
    with open(fetch("airports.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            kind = row["type"]
            scheduled = row["scheduled_service"] == "yes"
            if kind == "large_airport" or (kind == "medium_airport" and scheduled):
                code = row["icao_code"] or row["gps_code"] or row["ident"]
                if not code or len(code) != 4:
                    continue
                lat, lon = num(row["latitude_deg"]), num(row["longitude_deg"])
                if lat is None or lon is None:
                    continue
                airports[row["id"]] = {
                    "icao": code,
                    "iata": row["iata_code"] or None,
                    "name": row["name"],
                    "city": row["municipality"] or None,
                    "lat": round(lat, 5),
                    "lon": round(lon, 5),
                    "elev": int(num(row["elevation_ft"]) or 0),
                    "large": kind == "large_airport",
                    "runways": [],
                }

    with open(fetch("runways.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            airport = airports.get(row["airport_ref"])
            if airport is None or row["closed"] == "1":
                continue
            le_lat, le_lon = num(row["le_latitude_deg"]), num(row["le_longitude_deg"])
            he_lat, he_lon = num(row["he_latitude_deg"]), num(row["he_longitude_deg"])
            le_hdg, he_hdg = num(row["le_heading_degT"]), num(row["he_heading_degT"])
            if le_hdg is None and None not in (le_lat, le_lon, he_lat, he_lon):
                le_hdg = bearing(le_lat, le_lon, he_lat, he_lon)
            if le_hdg is None:
                le_hdg = heading_from_ident(row["le_ident"])
            if le_hdg is None:
                continue
            if he_hdg is None:
                he_hdg = (le_hdg + 180) % 360
            ends = [{"id": row["le_ident"], "hdg": round(le_hdg, 1)}]
            if row["he_ident"]:
                ends.append({"id": row["he_ident"], "hdg": round(he_hdg, 1)})
            airport["runways"].extend(ends)

    out = sorted(airports.values(), key=lambda a: (not a["large"], a["icao"]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    large = sum(1 for a in out if a["large"])
    print(f"{len(out)} airports ({large} large) -> {os.path.relpath(OUT, ROOT)}")
    kbos = next((a for a in out if a["icao"] == "KBOS"), None)
    if not kbos or not kbos["runways"]:
        sys.exit("KBOS or its runways missing: check the source data.")
    print("KBOS runways:", ", ".join(r["id"] for r in kbos["runways"]))


if __name__ == "__main__":
    main()
