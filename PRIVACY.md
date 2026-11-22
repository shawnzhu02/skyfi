# Skyfi privacy

Skyfi has no account and no server of its own. It collects nothing about you.

- **Flight data.** To show planes, the app asks the public ADS-B services adsb.lol and adsb.fi for aircraft around the airport you connect to. Those requests carry the airport's position, not yours. Tapping a plane may ask adsb.lol for that flight's route.
- **Tower audio.** Connecting to an airport opens LiveATC.net's own player page inside Skyfi. LiveATC sees that visit like any visit to its site (including its Cloudflare check and any cookies it sets). Links on that page that lead elsewhere open in Safari.
- **Weather.** Airport cards ask aviationweather.gov (NOAA) for the airport's weather report and atis.info for its ATIS broadcast. Those requests carry only the airport code.
- **Music.** Playing a YouTube link or preset fetches its audio from YouTube on your phone. If that fails, the open-source YouTubeKit library may relay the request through its public helper server. Radio presets stream from their own hosts (laut.fm, ilovemusic.de).
- **Location (optional).** Only if you tap the locate button and allow it: Skyfi uses your position on the phone to center the map and suggest the nearest airport. It is never sent anywhere.
- **Who's talking (optional).** Turning it on downloads an ATC speech model (about 490 MB) from Hugging Face once. After that, tower audio is transcribed on your phone; no audio or text leaves it.
- **Favorites, recents and the debug log** stay on your phone. The debug log leaves only if you copy or share it yourself.
- These services see your IP address, as any website would. Skyfi sends them nothing else.
- Skyfi does not use your contacts, camera or microphone, and has no analytics or ads.

Questions: use the TestFlight feedback button.
