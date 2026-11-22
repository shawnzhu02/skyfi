# Skyfi

A live flight globe with a soundtrack (iPhone, SwiftUI).

- 3D globe with live planes from the free ADS-B feeds adsb.lol (adsb.fi as fallback). Planes glide between polls.
- Takeoffs and landings show up live with the runway, per airport and in the Activity list.
- Tune an airport's tower (LiveATC.net) and mix it with 24/7 lofi or the audio of any YouTube link.
- Who's talking (branch `talk`): an ATC-trained Whisper model on the phone transcribes the tower, matches the callsign to a plane near the airport and makes it glow on the map.
- Audio keeps playing with the app closed or the phone locked, with lock-screen controls.

Built in the cloud by GitHub Actions and shipped through TestFlight. See [SETUP.md](SETUP.md).
Plan and phase 2 ("who is talking"): [docs/PLAN.md](docs/PLAN.md).
