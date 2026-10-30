#!/usr/bin/env python3
"""Generate apple/Tests/Fixtures/pocket-wheel-history.json — the deterministic 3-week Pocket
Wheel scenario (docs/design/pocket-wheel.md §6 Phase 2). Shared byte-for-byte with Android.

  weekdays 08:00 CarPlay from "Potential" (a source playlist, explicit origin)
  Saturday 09:00 running — Browse singles of ♥'d songs (no origin → Favorites membership)
  evenings 21:00 Mix from the "Late Night" crate (origin on every play)
  weekday lunch 12:00 Browse singles (no origin → hard memberships; the mega "Library" excluded)
  Sunday 15:00 one trip A→B from "Roadtrip"
  sprinkled skips + a one-off Thursday 03:00 play
Re-run after changing the scenario; the tests pin its derived numbers.
"""
import json, uuid, os

NS = uuid.UUID("6d1f3b8a-0000-4000-8000-000000000000")
TZ = -420                                   # PDT
DAY = 86_400_000
HOUR = 3_600_000
# "now" = Wednesday 2026-10-28 12:30 local (19:30Z).
NOW = 1_793_215_800_000
assert (NOW + TZ * 60_000) % DAY == 12.5 * HOUR

def local_ms(days_ago, hour, minute=0):
    # local midnight of today, minus days, plus time
    local_now = NOW + TZ * 60_000
    midnight = local_now - (local_now % DAY)
    return midnight - days_ago * DAY + hour * HOUR + minute * 60_000 - TZ * 60_000

def dow_of(ms):
    local = ms + TZ * 60_000
    day = local // DAY
    return ((day % 7) + 3) % 7 + 1          # ISO, 1970-01-01 = Thu

songs = {}
def song(sid, artist, genre, bpm, year):
    songs[sid] = {"artist": artist, "genre": genre, "bpm": bpm, "year": year}
    return sid

pot = []
artists = ["Drake", "Bryson Tiller", "6LACK", "dvsn", "Majid Jordan", "PARTYNEXTDOOR", "SZA", "Frank Ocean"]
for i in range(24):
    pot.append(song(f"pot_{i}", artists[i % len(artists)], "r&b" if i % 3 else "hip-hop", 88 + (i % 6) * 4, 2012 + i % 10))
late = [song(f"late_{i}", ["Massive Attack", "Portishead", "Tricky", "Burial"][i % 4], "electronic", 70 + i * 2, 1994 + i % 8) for i in range(12)]
fav = [song(f"fav_{i}", ["Daft Punk", "Justice", "Chromeo"][i % 3], "electronic", 120 + i, 2005 + i % 6) for i in range(10)]
road = [song(f"road_{i}", ["Tom Petty", "Fleetwood Mac"][i % 2], "rock", 110 + i, 1977 + i) for i in range(8)]
lunch = [song(f"lun_{i}", ["Khruangbin", "Tycho"][i % 2], "electronic", 96 + i, 2016 + i % 4) for i in range(8)]
filler = [song(f"lib_{i}", "Various", "pop", 100, 2000) for i in range(60)]
library = pot + late + fav + road + lunch + filler

collections = [
    {"id": "pl_potential", "name": "Potential", "songIds": pot},
    {"id": "pkt_late", "name": "Late Night", "songIds": late},
    {"id": "fav_songs", "name": "Favorite songs", "songIds": fav + pot[:2]},
    {"id": "pls_road", "name": "Roadtrip", "songIds": road},
    {"id": "pkt_chill", "name": "Chill Lunch", "songIds": lunch},
    {"id": "pl_library", "name": "Library", "songIds": library},     # mega (> 25 % of library)
]

events = []
n = 0
def ev(sid, ms, source, origin=None, context_id=None, carplay=None, motion=None, skipped=None,
       fraction=None, ctx=None, name=None):
    global n
    n += 1
    e = {"id": str(uuid.uuid5(NS, f"e{n}")).upper(), "songId": sid, "playedAt": ms, "source": source,
         "originInstallId": "fixture-install", "tzOffsetMin": TZ}
    if context_id: e["contextId"] = context_id
    if name: e["contextName"] = name
    if origin: e["originCollectionId"] = origin
    if carplay is not None: e["carPlay"] = carplay
    if motion: e["motion"] = motion
    if skipped: e["wasSkipped"] = True
    if fraction is not None: e["listenedFraction"] = fraction
    if ctx: e["listeningContext"] = ctx
    events.append(e)

for d in range(21, 0, -1):
    t = local_ms(d, 0)
    dow = dow_of(t)
    if dow <= 5:
        # 08:00 CarPlay Potential — 3 songs, Drake skipped on Mondays.
        for k in range(3):
            sid = pot[(d * 3 + k) % len(pot)]
            skip = (dow == 1 and k == 0)
            ev(sid, local_ms(d, 8, 5 + k * 4), "playlist", origin="pl_potential", context_id="set_now_playing",
               carplay=True, skipped=skip, fraction=0.1 if skip else 1.0, name="Potential")
        # 12:00 lunch Browse singles (no origin)
        ev(lunch[d % len(lunch)], local_ms(d, 12, 10), "browser", fraction=1.0)
        ev(lunch[(d + 3) % len(lunch)], local_ms(d, 12, 20), "browser", fraction=1.0)
    if dow == 6:
        # Saturday 09:00 running, ♥'d songs from Browse
        for k in range(4):
            ev(fav[(d + k) % len(fav)], local_ms(d, 9, k * 4), "browser", motion="running", fraction=1.0)
    if dow == 7:
        ev(road[d % len(road)], local_ms(d, 15, 0), "playlist", origin="pls_road", context_id="set_now_playing",
           ctx={"kind": "trip", "tripId": "trp_ab", "origin": "plc_a", "destination": "plc_b"}, fraction=1.0, name="Roadtrip")
        ev(road[(d + 1) % len(road)], local_ms(d, 15, 4), "playlist", origin="pls_road", context_id="set_now_playing",
           ctx={"kind": "trip", "tripId": "trp_ab", "origin": "plc_a", "destination": "plc_b"}, fraction=1.0, name="Roadtrip")
    # 21:00 Mix from Late Night, every evening
    ev(late[d % len(late)], local_ms(d, 21, 0), "mix", origin="pkt_late", context_id="mxs_1", fraction=1.0, name="Late Night")
    ev(late[(d + 5) % len(late)], local_ms(d, 21, 5), "mix", origin="pkt_late", context_id="mxs_1",
       skipped=(d % 5 == 0), fraction=0.2 if d % 5 == 0 else 1.0, name="Late Night")

# one-off: Thursday 03:00 two weeks ago
for d in range(21, 0, -1):
    if dow_of(local_ms(d, 0)) == 4 and d > 10:
        ev(filler[0], local_ms(d, 3, 0), "browser", fraction=1.0)
        break
# a game play (excluded)
ev(pot[0], local_ms(2, 10, 0), "game", fraction=1.0, name="In the Pocket")

events.sort(key=lambda e: e["playedAt"])
doc = {"nowMs": NOW, "tzOffsetMin": TZ, "librarySize": len(library), "songs": songs,
       "collections": collections, "events": events}
out = os.path.join(os.path.dirname(__file__), "..", "Tests", "Fixtures", "pocket-wheel-history.json")
with open(out, "w") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
    f.write("\n")
print("events", len(events), "songs", len(songs))
