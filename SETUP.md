# Skyfi setup

Skyfi is an iPhone app (SwiftUI). GitHub Actions builds it on a Mac in the cloud and uploads it to TestFlight, the same way Sift ships. Do these steps once, in this order.

## 1. Register the bundle ID

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click **+**, choose **App IDs**, then **App**.
3. Description: `Skyfi`. Bundle ID: **Explicit**, `com.shawnzhu.skyfi`.
4. Don't tick any capabilities (background audio needs none). Click **Continue**, then **Register**.

## 2. Create the app in App Store Connect

1. Go to https://appstoreconnect.apple.com/apps
2. Click **+**, then **New App**.
3. Platform **iOS**, name `Skyfi` (if taken, try `Skyfi Radio`), language English, bundle ID `com.shawnzhu.skyfi`, SKU `skyfi`.
4. Choose **Full Access** and click **Create**.

## 3. Give GitHub the App Store Connect key

The Sift key works here too (it's an Admin team key, not tied to one app). Run these in Git Bash with the same values you used for Sift:

```bash
cd ~/Programming/skyfi
gh secret set ASC_KEY_ID --body "YOUR_KEY_ID"
gh secret set ASC_ISSUER_ID --body "YOUR_ISSUER_ID"
gh secret set APPLE_TEAM_ID --body "YOUR_TEAM_ID"
gh secret set ASC_KEY_P8 < /path/to/AuthKey_YOUR_KEY_ID.p8
```

## 4. Build and install

1. Start a build: `gh workflow run iOS` (or push any Swift change). Watch it with `gh run watch`.
2. When the run is green, wait 5-15 minutes for Apple to process the build.
3. In App Store Connect, open Skyfi, then **TestFlight**. Under **Internal Testing**, create a group, add yourself, and add the build.
4. On your iPhone, open **TestFlight** and install Skyfi.

## 5. Check on the phone

- Zoom in near Boston: planes glide, and pinching out turns the map into a globe.
- Tap **BOS**, then **Boston Tower**. In the mixer at the bottom, start Lofi Girl, then paste a YouTube link.
- Lock the phone: both keep playing; play/pause works on the lock screen. Take a call: audio comes back after.
- Watch the Activity list (top right) for takeoffs and landings with runways.

## Friends beta (TestFlight public link)

Same as Sift. Set these once from Git Bash in this folder:

```bash
gh gist create --secret PRIVACY.md            # copy the gist URL it prints
gh variable set BETA_PRIVACY_URL --body "https://gist.github.com/..."
gh variable set BETA_FEEDBACK_EMAIL --body "you@example.com"
gh variable set BETA_CONTACT_FIRST --body "First"
gh variable set BETA_CONTACT_LAST --body "Last"
gh variable set BETA_CONTACT_EMAIL --body "you@example.com"
gh secret set BETA_CONTACT_PHONE --body "+1 555 555 5555"
```

Then, for each build you want friends on: `gh workflow run beta.yml` (optionally `-f build=3`). It submits the build to Beta App Review. Run it again after Apple approves to print the `testflight.apple.com/join/...` link.

Beta App Review may push back on YouTube audio playback or LiveATC streaming. Internal testers (people added to the App Store Connect team) skip that review.

## Data and upkeep

- `python scripts/build_airports.py` rebuilds `Skyfi/Resources/airports.json` from OurAirports (large airports, plus medium ones with airline service).
- `python scripts/check_sources.py` checks the lofi presets and LiveATC mounts. Presets are in `Skyfi/Resources/presets.json`, tower feeds in `Skyfi/Resources/feeds.json` (LiveATC mount names, for example `kbos_twr`). Changing either needs a new build for now.
- `python scripts/make_icon.py` redraws the app icon.

## Known limits

- adsb.lol and adsb.fi are free, non-commercial feeds; each query covers up to 250 nm. Zoomed far out, Skyfi polls the 9 areas nearest the middle of the screen and says "Zoom in to see all live traffic".
- LiveATC's terms are for personal, non-commercial listening. Fine for a small private beta; a public App Store release would need their written permission.
- Extracting YouTube audio goes against YouTube's terms and can break when YouTube changes things. If on-device extraction stops working, the fallback plan is a small yt-dlp proxy on the Oracle box (see docs/PLAN.md).
- GitHub's free plan gives a private repo about 200 macOS minutes a month. One build with tests uses about 10-15.
