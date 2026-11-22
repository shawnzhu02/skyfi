"""Checks that the bundled music presets and LiveATC feeds still answer.

    python scripts/check_sources.py

YouTube IDs are checked through YouTube's public oEmbed endpoint. Radio streams
and LiveATC mounts get a short ranged GET. LiveATC may refuse scripted requests
(it answers 404 to plain clients), so a failing mount here is a hint, not proof:
confirm it in the app.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Skyfi", "Resources")


def status(url):
    req = urllib.request.Request(url, headers={"Range": "bytes=0-1000"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:  # timeouts, DNS
        return 0, type(e).__name__


def main():
    bad = 0
    for p in json.load(open(os.path.join(RES, "presets.json"), encoding="utf-8")):
        if p["kind"] == "youtube":
            watch = "https://www.youtube.com/watch?v=" + p["value"]
            code, _ = status("https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(watch, safe=""))
        else:
            code, _ = status(p["value"])
        ok = code in (200, 206)
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} preset {p['id']:<14} {code}")
    for f in json.load(open(os.path.join(RES, "feeds.json"), encoding="utf-8")):
        code, kind = status(f"http://d.liveatc.net/{f['mount']}")
        ok = code in (200, 206) and "audio" in kind
        print(f"{'ok ' if ok else '?  '} feed   {f['mount']:<14} {code} {kind}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
