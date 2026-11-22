"""Builds Skyfi/Resources/feeds.json: the airports you can connect to and their LiveATC mounts.

Each airport gets up to three candidates, tried in order: tower, approach, departure.
The app plays only one at a time and falls back to the next when a mount is offline.
Mount names follow LiveATC's usual <icao>_twr / _app / _dep pattern and are unverified
until checked on a phone (Mixer sheet > Check feeds): fix or drop dead ones here.

Run: python scripts/build_feeds.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Skyfi", "Resources", "feeds.json")

# ICAO, spoken facility name. Roughly the 40 busiest US airports, then a few abroad.
US = [
    ("KATL", "Atlanta"), ("KDFW", "Dallas/Fort Worth"), ("KDEN", "Denver"), ("KORD", "Chicago O'Hare"),
    ("KLAX", "Los Angeles"), ("KJFK", "Kennedy"), ("KLAS", "Las Vegas"), ("KMCO", "Orlando"),
    ("KMIA", "Miami"), ("KCLT", "Charlotte"), ("KSEA", "Seattle"), ("KPHX", "Phoenix"),
    ("KEWR", "Newark"), ("KSFO", "San Francisco"), ("KIAH", "Houston"), ("KBOS", "Boston"),
    ("KFLL", "Fort Lauderdale"), ("KMSP", "Minneapolis"), ("KLGA", "LaGuardia"), ("KDTW", "Detroit"),
    ("KPHL", "Philadelphia"), ("KSLC", "Salt Lake City"), ("KBWI", "Baltimore"), ("KDCA", "Washington National"),
    ("KSAN", "San Diego"), ("KIAD", "Dulles"), ("KTPA", "Tampa"), ("KBNA", "Nashville"),
    ("KAUS", "Austin"), ("KMDW", "Chicago Midway"), ("PHNL", "Honolulu"), ("KDAL", "Dallas Love"),
    ("KPDX", "Portland"), ("KSTL", "St. Louis"), ("KSJC", "San Jose"), ("KOAK", "Oakland"),
    ("KRDU", "Raleigh-Durham"), ("KMCI", "Kansas City"), ("KSMF", "Sacramento"), ("KSAT", "San Antonio"),
    ("KMSY", "New Orleans"),
]
# Abroad: tower only for now.
ABROAD = [("CYYZ", "Toronto"), ("EGLL", "Heathrow"), ("EHAM", "Schiphol"), ("RJTT", "Haneda")]

KINDS = [("tower", "twr", "Tower"), ("approach", "app", "Approach"), ("departure", "dep", "Departure")]


def main():
    feeds = []
    for icao, name in US:
        for kind, suffix, label in KINDS:
            feeds.append({"mount": f"{icao.lower()}_{suffix}", "airport": icao, "name": f"{name} {label}", "kind": kind})
    for icao, name in ABROAD:
        feeds.append({"mount": f"{icao.lower()}_twr", "airport": icao, "name": f"{name} Tower", "kind": "tower"})
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(feeds, f, indent=1)
        f.write("\n")
    print(f"{len(US) + len(ABROAD)} airports, {len(feeds)} mounts -> {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
