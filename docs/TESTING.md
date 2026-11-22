# Device test checklist

Run this on the newest TestFlight build. If something fails, open Mixer > Debug log > Share and send the report: it has every page load, HTTP status, player event and error.

## Tower audio (LiveATC's own player)

1. Tap a cyan airport (BOS), then Connect. The LiveATC panel opens over the bottom of the map, and BOS planes appear within about 5 s.
2. If LiveATC shows "Just a moment…" (Cloudflare), wait. It should pass by itself. After 20 s the panel offers "Open in Safari".
3. Tap play on LiveATC's page. The mini status should say "Live from LiveATC.net".
4. Start lofi in the mixer: music and tower play together. Balance them with the music volume.
5. Minimize the panel (chevron, or drag the header down). Audio keeps going and the map is usable. Drag the header up for a taller panel. The chips under the page switch to your other airports.
6. Lock the phone. Audio keeps going. Pause and play from the lock screen.
7. Tap the list icon in the panel for every BOS feed and pick another one. The mixer bar follows it.
8. Tap ✕ (Stop tower): planes stay. The airport card now says "Start tower"; tap it to start again.
9. Pause in the mixer, then tap play on LiveATC's page: both resume.
10. Disconnect from the airport card: the panel closes and the planes clear.

If step 3 or 6 fails, note what the debug log says under `[web]`.

## Airport card

- Weather row (VFR/MVFR/IFR/LIFR, wind, visibility). Tap it for the raw METAR.
- ATIS row (letter, landing and departing runways). Tap it for the full broadcast.
- Local time and Zulu under the name.
- Forecast row (VFR now, then IFR at 2300Z); open it for each period and the raw TAF.
- Frequencies (tap to open): tower, ground, approach and the rest.
- Connected: runways drawn on the map; the ones in use are cyan.
- Star in the top right: the airport shows ★ on the map and under "Your airports" in the mixer.
- When connected: on-approach list with runway, ETA and origin, plus last-hour landings and takeoffs.
- An airport without a Skyfi feed list: "Find feeds on LiveATC" opens LiveATC's page for it.

## Planes

- Tap a plane: likely frequency (ON: TWR 128.8), trail, landing ETA when on approach, route bar (BOS ━✈── LAX, nm to go).
- A plane that stops reporting shows "No signal for N s" and follow pauses.
- Follow: the map keeps it centered. Dragging the map stops following.
- FlightAware and Share buttons.
- Activity (list icon) > search "DAL" finds Delta flights on the map.
- About > Map > Color planes by altitude.

## Other

- Locate button: asks for location once, centers on you, offers the nearest airport.
- Mixer > moon icon: sleep timer (try 15 min, then turn it off).
- Second launch: "Resume BOS + <music>" chip.
- Siri: "Connect to BOS in Skyfi" (or Shortcuts app > Skyfi).
- Safari: `skyfi://connect/JFK` opens Skyfi connected to JFK.
