"""Builds Skyfi/Resources/telephony.json: ICAO airline code -> spoken radio callsign.

Source: OpenFlights airlines.dat (Open Database License), plus hand fixes for
airlines whose OpenFlights callsign is wrong or missing. Run from the repo root:

    python scripts/build_telephony.py
"""

import csv
import json
import os
import re
import urllib.request

URL = "https://raw.githubusercontent.com/jpatokal/openflights/master/data/airlines.dat"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "data", "airlines.dat")
OUT = os.path.join(ROOT, "Skyfi", "Resources", "telephony.json")

# Checked by hand: busy US/Canada carriers and common international ones.
FIXES = {
    "AAL": "american", "AAY": "allegiant", "ABX": "abex", "ACA": "air canada", "AFR": "airfrans",
    "AMX": "aeromexico", "ANA": "all nippon", "ASA": "alaska", "ASH": "air shuttle", "ATN": "air transport",
    "AUA": "austrian", "AVA": "avianca", "BAW": "speedbird", "CCA": "air china", "CES": "china eastern",
    "CJC": "colgan", "CKS": "connie", "CMP": "copa", "CPA": "cathay", "CPZ": "compass", "CSN": "china southern",
    "DAL": "delta", "DLH": "lufthansa", "EDV": "endeavor", "EIN": "shamrock", "EJA": "execjet", "ENY": "envoy",
    "ETD": "etihad", "FDX": "fedex", "FFT": "frontier flight", "GJS": "lindbergh", "GTI": "giant",
    "HAL": "hawaiian", "IBE": "iberia", "ICE": "iceair", "JAL": "japan air", "JBU": "jetblue",
    "JIA": "blue streak", "JZA": "jazz", "KAL": "korean air", "KLM": "klm", "LXJ": "flexjet", "MXY": "moxy",
    "NKS": "spirit wings", "PDT": "piedmont", "POE": "porter", "QFA": "qantas", "QTR": "qatari",
    "QXE": "horizon", "ROU": "rouge", "RPA": "brickyard", "SAS": "scandinavian", "SCX": "sun country",
    "SIA": "singapore", "SKW": "skywest", "SWA": "southwest", "SWR": "swiss", "TAP": "air portugal",
    "THY": "turkish", "TSC": "air transat", "UAE": "emirates", "UAL": "united", "UPS": "u p s",
    "VIR": "virgin", "VOI": "volaris", "VXP": "avelo", "WJA": "westjet",
}


def clean(callsign):
    text = re.sub(r"[^a-z ]", " ", callsign.lower())
    return " ".join(text.split())


def main():
    if not os.path.exists(SRC):
        os.makedirs(os.path.dirname(SRC), exist_ok=True)
        urllib.request.urlretrieve(URL, SRC)
    table = {}
    with open(SRC, encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) < 8:
                continue
            icao, callsign, active = row[4].strip(), row[5].strip(), row[7].strip()
            if not re.fullmatch(r"[A-Z]{3}", icao) or not callsign or callsign == "\\N":
                continue
            spoken = clean(callsign)
            if not spoken or len(spoken) < 3:
                continue
            # Prefer active airlines when a code was reused.
            if icao not in table or active == "Y":
                table[icao] = spoken
    table.update(FIXES)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(table.items())), f, separators=(",", ":"))
    print(f"{len(table)} airline callsigns -> {os.path.relpath(OUT, ROOT)}")
    for code in ("DAL", "BAW", "RPA", "JBU", "ASA"):
        print(f"  {code} = {table[code]}")


if __name__ == "__main__":
    main()
