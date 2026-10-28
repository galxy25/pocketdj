state: in-progress

# MIX-16 Integrations: Jukebox <-> Mix, MixPlayOutcomeBridge, MixFacadeImpl
- [x] MixPlayOutcomeBridge (deck-keyed, async event resolution, verdict table)
- [x] MixJukeboxSource + MixJukeboxPort + MixJukeboxSeam; JukeboxRepository prefers the live mix (snapshot, placement, pending drain)
- [x] MixFacadeImpl + MixGraph wiring (bridge hooks, jukebox seam, facade; ports shared with mixViewModel)
- [ ] Tests, specs/mix.md
