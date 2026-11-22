# Skyfi

A live flight globe with a soundtrack (iPhone, SwiftUI).

- 3D globe with live planes from the free ADS-B feeds adsb.lol (adsb.fi as fallback). Planes glide between polls.
- Takeoffs and landings show up live with the runway, per airport and in the Activity list.
- Connect to an airport: its planes within 60 nm, and its tower in LiveATC.net's own player (LiveATC blocks app players), next to 24/7 lofi or the audio of any YouTube link.
- Airport cards: weather (METAR, flight category), ATIS with runways in use, planes on approach with runway and ETA, last-hour landings and takeoffs, a feed picker, favorites.
- Plane cards: likely frequency (GND/TWR/DEP/APP/CTR), trail, follow mode, FlightAware link, share. Emergency squawks show in red.
- Search airports and flights, recents, near me, sleep timer, a debug log to share.
- Who's talking: an ATC-trained Whisper model on the phone transcribes the tower, matches the callsign to a plane near the airport and makes it glow on the map. It needs Skyfi's own player, which LiveATC currently refuses.
- Audio keeps playing with the app closed or the phone locked, with lock-screen controls.

Built in the cloud by GitHub Actions and shipped through TestFlight. See [SETUP.md](SETUP.md).
Plan and phase 2 ("who is talking"): [docs/PLAN.md](docs/PLAN.md).
