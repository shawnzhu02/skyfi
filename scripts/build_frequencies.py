"""Builds Skyfi/Resources/frequencies.json from the OurAirports open data.

Keeps the controller and information frequencies (ATIS, clearance, ground,
tower, approach, departure, CTAF) for the airports already in airports.json.
Run from the repo root after build_airports.py:

    python scripts/build_frequencies.py
"""

import csv
import json
import os
import urllib.request

BASE = "https://davidmegginson.github.io/ourairports-data/"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
AIRPORTS = os.path.join(ROOT, "Skyfi", "Resources", "airports.json")
OUT = os.path.join(ROOT, "Skyfi", "Resources", "frequencies.json")

# OurAirports type codes, mapped to the label Skyfi shows, in the order a flight uses them.
KINDS = {
    "ATIS": "ATIS", "D-ATIS": "ATIS", "AWOS": "ATIS", "ASOS": "ATIS",
    "CLD": "DEL", "DEL": "DEL", "CLNC": "DEL",
    "GND": "GND",
    "TWR": "TWR",
    "DEP": "DEP",
    "APP": "APP", "A/D": "APP", "TRACON": "APP",
    "CTAF": "CTAF", "UNIC": "CTAF",
}
ORDER = ["ATIS", "DEL", "GND", "TWR", "DEP", "APP", "CTAF"]


WORDS = {
    "TWR": "Tower", "APP": "Approach", "DEP": "Departure", "GND": "Ground", "CLNC": "Clearance",
    "DEL": "Delivery", "CLD": "Clearance", "CTR": "Center", "RDO": "Radio", "INFO": "Info",
    "ARR": "Arrival", "APCH": "Approach", "CTAF": "CTAF", "ATIS": "ATIS", "D-ATIS": "D-ATIS",
    "AWOS": "AWOS", "ASOS": "ASOS", "UNICOM": "Unicom", "UNIC": "Unicom", "N": "North",
    "S": "South", "E": "East", "W": "West", "TRACON": "TRACON",
}


def tidy(text):
    """"BOSTON TWR WEST" -> "Boston Tower West"; keeps ATIS-style acronyms."""
    words = []
    for word in text.strip().split():
        key = word.upper().strip("()")
        if key in WORDS:
            words.append(word.upper().replace(key, WORDS[key]))
        else:
            words.append(word.capitalize() if word.isupper() or word.islower() else word)
    return " ".join(words)


def fetch(name):
    path = os.path.join(DATA, name)
    if not os.path.exists(path):
        os.makedirs(DATA, exist_ok=True)
        print(f"Downloading {name}")
        urllib.request.urlretrieve(BASE + name, path)
    return path


def main():
    with open(AIRPORTS, encoding="utf-8") as f:
        wanted = {a["icao"] for a in json.load(f)}
    found = {}
    with open(fetch("airport-frequencies.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            icao = row["airport_ident"]
            kind = KINDS.get(row["type"].upper())
            if icao not in wanted or not kind:
                continue
            try:
                mhz = round(float(row["frequency_mhz"]), 3)
            except ValueError:
                continue
            if not 108 <= mhz <= 137:  # VHF airband only
                continue
            name = tidy(row["description"] or row["type"])
            entry = [kind, name, mhz]
            found.setdefault(icao, [])
            if entry not in found[icao]:
                found[icao].append(entry)
    for entries in found.values():
        entries.sort(key=lambda e: (ORDER.index(e[0]), e[2]))
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(found, f, separators=(",", ":"), sort_keys=True)
    print(f"{len(found)} airports, {sum(map(len, found.values()))} frequencies -> {OUT}")


if __name__ == "__main__":
    main()
