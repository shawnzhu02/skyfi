# Skyfi privacy

Skyfi has no account and no server of its own. It collects nothing about you.

- **Flight data.** To show planes, the app asks the public ADS-B services adsb.lol and adsb.fi for aircraft around the part of the map you are looking at. Those requests carry the map position, not your location. Tapping a plane may ask adsb.lol for that flight's route.
- **Tower audio.** Tuning a tower streams it from LiveATC.net.
- **Music.** Playing a YouTube link or preset fetches its audio from YouTube on your phone. If that fails, the open-source YouTubeKit library may relay the request through its public helper server. Radio presets stream from their own hosts (laut.fm, ilovemusic.de).
- **Who's talking (optional).** Turning it on downloads an ATC speech model (about 1.5 GB) from Hugging Face once. After that, tower audio is transcribed on your phone; no audio or text leaves it.
- These services see your IP address, as any website would. Skyfi sends them nothing else.
- Skyfi does not use your location, contacts, camera or microphone, and has no analytics or ads.

Questions: use the TestFlight feedback button.
