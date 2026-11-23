# Device test checklist

Run this on the newest TestFlight build. If something fails, open Mixer > Debug log > Share and send the report: it has every page load, HTTP status, player event, feed list and error.

## Tower audio (LiveATC's own player)

1. Tap a blue airport (BOS), then the yellow **Listen live** button. The LiveATC panel opens and BOS planes appear within about 5 s.
2. Skyfi first opens LiveATC's page for the airport to read its real feeds and which are up, then switches to the first live one (tower, else approach, else departure). The debug log shows `LiveATC lists N feeds at KBOS: ...=up/down`.
3. If LiveATC shows "Just a moment…" (Cloudflare), wait. After 15 s Skyfi clears LiveATC's cookies and reloads once; if it's still stuck, the panel offers "Open in Safari".
4. Tap play on LiveATC's page. The top bar turns green: "Listening to Boston Tower".
5. Start lofi in the mixer: music and tower play together. The slider on the bottom player sets the music volume.
6. Panel ⋯ menu: "Feeds at KBOS" lists every feed with its status (down ones say "(down)"). Pick another one.
7. Minimize the panel (chevron, or drag the header down). Audio keeps going. Lock the phone: audio keeps going.
8. ✕ stops the tower; planes stay. "Listen again" on the airport card starts it again. "Stop listening" disconnects.

## Live subtitles (experiment)

1. With the tower playing, tap "Turn on live subtitles" above the player. iOS asks to allow recording Skyfi: allow.
2. The first time, the ATC speech model downloads (about 1.5 GB, Wi-Fi).
3. When the tower talks, the last two transmissions show as white text with the callsign in orange, and the map zooms to that plane (orange). Turn either off in About > Subtitles.
4. Music is in the recording too: turn it down if subtitles are wrong or missing.
5. If nothing ever shows, send the debug log: `recording: N sound buffers in 10 s, peak 0.000` means iOS doesn't include LiveATC's page sound in the recording, and subtitles need another way.

## Map and cards

- Planes are yellow; the picked plane and a plane being talked to are orange; emergencies red; ground grey.
- Plane card: callsign, airline/type, route, altitude, speed, Follow, FlightAware.
- Airport card: name, Listen live, weather, on approach, last takeoffs and landings. "ATIS, forecast and frequencies" opens the rest.
- Activity list (top right): takeoffs and landings, and search for any flight worldwide (DAL234, N123AB).
- Siri: "Connect to BOS in Skyfi", "Weather at BOS in Skyfi", "Pause Skyfi".
- About: tower player switch, subtitles, map options (altitude colors, data blocks, hide ground, keep screen on).
