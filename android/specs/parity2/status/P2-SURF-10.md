state: reviewed

# P2-SURF-10: Mix Mode on/off and mute/unmute stems by voice, deep link and App Actions

- [x] StemPart (iOS synonyms; no "Drop the <stem>") + NowPlayingVoicePort/NowPlayingVoiceActions (iOS order of operations and sentences)
- [x] ShellActions.setNowPlayingMixMode / setStem (veto + ensureReady, Main dispatcher), MixTabLive exception, link seams
- [x] Deep links pocketdj://np/mixmode?on=, pocketdj://np/stem/<name>?mute= (DeepLinkParser + dispatcher seams + ShellGraph wiring)
- [x] App Actions capabilities SET_MIX_MODE / MUTE_STEM / UNMUTE_STEM (shortcuts.xml, app_actions.xml)
- [x] 18 new JVM tests (7673 total, 0 failures); testDebugUnitTest + assembleDebug + assembleRelease green

## Deviations / files outside owned set
- Touched DeepLinkDispatcher.kt (exhaustive `when` + two seams) and di/ShellGraph.kt (wiring), additive.
- Missing `on`/`mute` flag defaults to on / mute (iOS intent defaults).
- setNowPlayingMixMode does not refuse while the Mix tab is live (iOS parity: it just says buffering waits); stems refuse.
- First assembleRelease hit a Kotlin backend internal error once; rerun was green (flake under load).

## Questions for Levi
None.

## Review
- MINOR DeepLinkParser.flag defaulting unknown to on -> fixed (explicit on/off synonym sets incl. disable/stop; unrecognized returns Unresolved)
- MINOR silent no-op setMixMode reported as on -> fixed (re-reads mixModeEnabled; says "isn't available right now"; setStem only sets turnedOn when flipped)
- NIT wrong exception wording -> fixed (new MixModeUnavailable)

fixes applied
