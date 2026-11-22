"""Sets up the friends' TestFlight beta in App Store Connect and sends a build.

Runs in GitHub Actions (.github/workflows/beta.yml) with the App Store
Connect API key from the repo secrets. Every step is idempotent: run it again
for each new build.

1. Test information: beta description, feedback email, privacy policy link.
2. Beta App Review contact details and reviewer notes.
3. An external group "Friends" with a public TestFlight link.
4. The newest processed build (or BUILD_NUMBER): "What to test", added to
   the group, and sent to Beta App Review.
5. Prints the public link.
"""

import json
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.shawnzhu.skyfi"
GROUP_NAME = "Friends"
LINK_LIMIT = int(os.environ.get("BETA_LINK_LIMIT") or "50")

DESCRIPTION = (
    "Skyfi is a live flight globe with a soundtrack. Spin the globe to watch planes "
    "in real time, see takeoffs and landings at airports as they happen, and tune "
    "into the tower's radio. Mix the tower with 24/7 lofi or audio from any YouTube "
    "link, and keep listening with the app closed or the phone locked. Skyfi has no "
    "account and collects nothing."
)

WHAT_TO_TEST = (
    "Zoom in near a big airport (Boston, JFK, LAX). Planes should glide smoothly and "
    "takeoffs and landings should show up in the Activity list with the runway. Tap "
    "the airport and tune the tower, then open the mixer, start a lofi preset or "
    "paste a YouTube link, and set the mix. Lock your phone: both should keep "
    "playing, with play/pause on the lock screen. Tell us about any tower feed that "
    "won't connect, any link that won't play, or anything that stutters."
)

REVIEW_NOTES = (
    "Skyfi has no account or server of its own. Plane positions come from the free "
    "community ADS-B feeds adsb.lol and adsb.fi; tower audio is the public LiveATC.net "
    "stream for each airport. No sign-in is needed: open the app, zoom in near an "
    "airport, tap it and choose a tower feed, then open the mixer at the bottom to "
    "add music. Audio keeps playing in the background, which is why the app uses the "
    "audio background mode."
)


def env(name, required=True):
    value = os.environ.get(name, "").strip()
    if required and not value:
        sys.exit(f"Missing {name}. See SETUP.md, 'Friends beta'.")
    return value


def token():
    key = env("ASC_KEY_P8").replace("\\n", "\n")
    now = int(time.time())
    return jwt.encode(
        {"iss": env("ASC_ISSUER_ID"), "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": env("ASC_KEY_ID"), "typ": "JWT"},
    )


SESSION = requests.Session()


def call(method, path, body=None, params=None, ok=(200, 201, 204)):
    SESSION.headers["Authorization"] = f"Bearer {token()}"
    r = SESSION.request(method, API + path, json=body, params=params, timeout=60)
    if r.status_code not in ok:
        sys.exit(f"{method} {path} failed ({r.status_code}): {r.text[:800]}")
    return r.json() if r.content else {}


def find_app():
    data = call("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not data:
        sys.exit(f"No app with bundle id {BUNDLE_ID} in App Store Connect.")
    return data[0]["id"]


def set_test_info(app_id):
    attrs = {
        "description": DESCRIPTION,
        "feedbackEmail": env("BETA_FEEDBACK_EMAIL"),
        "privacyPolicyUrl": env("BETA_PRIVACY_URL"),
    }
    existing = call("GET", f"/apps/{app_id}/betaAppLocalizations")["data"]
    mine = next((l for l in existing if l["attributes"]["locale"] == "en-US"), None)
    if mine:
        call("PATCH", f"/betaAppLocalizations/{mine['id']}",
             {"data": {"type": "betaAppLocalizations", "id": mine["id"], "attributes": attrs}})
    else:
        call("POST", "/betaAppLocalizations", {"data": {
            "type": "betaAppLocalizations",
            "attributes": {"locale": "en-US", **attrs},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
    print("Test information set.")


def set_review_details(app_id):
    detail = call("GET", f"/apps/{app_id}/betaAppReviewDetail")["data"]
    call("PATCH", f"/betaAppReviewDetails/{detail['id']}", {"data": {
        "type": "betaAppReviewDetails",
        "id": detail["id"],
        "attributes": {
            "contactFirstName": env("BETA_CONTACT_FIRST"),
            "contactLastName": env("BETA_CONTACT_LAST"),
            "contactPhone": env("BETA_CONTACT_PHONE"),
            "contactEmail": env("BETA_CONTACT_EMAIL"),
            "demoAccountRequired": False,
            "notes": REVIEW_NOTES,
        },
    }})
    print("Beta App Review details set.")


def friends_group(app_id):
    groups = call("GET", "/betaGroups", params={"filter[app]": app_id, "filter[name]": GROUP_NAME})["data"]
    groups = [g for g in groups if not g["attributes"].get("isInternalGroup")]
    if groups:
        return groups[0]["id"]
    created = call("POST", "/betaGroups", {"data": {
        "type": "betaGroups",
        "attributes": {"name": GROUP_NAME, "feedbackEnabled": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})["data"]
    print(f"Created external group '{GROUP_NAME}'.")
    return created["id"]


def public_link(group_id):
    """Turns on the public link. Apple can refuse until a build is approved."""
    SESSION.headers["Authorization"] = f"Bearer {token()}"
    r = SESSION.patch(f"{API}/betaGroups/{group_id}", timeout=60, json={"data": {
        "type": "betaGroups", "id": group_id,
        "attributes": {"publicLinkEnabled": True, "publicLinkLimitEnabled": True,
                       "publicLinkLimit": LINK_LIMIT},
    }})
    if r.status_code != 200:
        print(f"Public link not available yet ({r.status_code}): {r.text[:300]}")
        return None
    return r.json()["data"]["attributes"].get("publicLink")


def pick_build(app_id):
    params = {"filter[app]": app_id, "filter[processingState]": "VALID",
              "filter[expired]": "false", "sort": "-uploadedDate", "limit": 1}
    number = env("BUILD_NUMBER", required=False)
    if number:
        params["filter[version]"] = number
    data = call("GET", "/builds", params=params)["data"]
    if not data:
        sys.exit("No processed build found yet. Wait for Apple to finish processing, then run again.")
    build = data[0]
    print(f"Build {build['attributes']['version']} ({build['id']}).")
    return build["id"]


def set_what_to_test(build_id):
    existing = call("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    mine = next((l for l in existing if l["attributes"]["locale"] == "en-US"), None)
    if mine:
        call("PATCH", f"/betaBuildLocalizations/{mine['id']}",
             {"data": {"type": "betaBuildLocalizations", "id": mine["id"], "attributes": {"whatsNew": WHAT_TO_TEST}}})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": WHAT_TO_TEST},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})


def send_build(group_id, build_id):
    call("POST", f"/betaGroups/{group_id}/relationships/builds",
         {"data": [{"type": "builds", "id": build_id}]})
    current = call("GET", f"/builds/{build_id}/betaAppReviewSubmission", ok=(200, 404))
    state = ((current or {}).get("data") or {}).get("attributes", {}).get("betaReviewState")
    if state:
        print(f"Already submitted to Beta App Review: {state}.")
        return
    call("POST", "/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
    }}, ok=(200, 201, 409))
    print("Sent to Beta App Review. Apple usually answers within a day.")


def main():
    app_id = find_app()
    set_test_info(app_id)
    set_review_details(app_id)
    group_id = friends_group(app_id)
    build_id = pick_build(app_id)
    set_what_to_test(build_id)
    send_build(group_id, build_id)
    link = public_link(group_id)
    if link:
        print(f"::notice::Friends' TestFlight link: {link}")
    else:
        print("::notice::Public link appears once Apple approves the first build. Run this again then to print it.")
    print(json.dumps({"group": GROUP_NAME, "publicLink": link, "limit": LINK_LIMIT}))


if __name__ == "__main__":
    main()
