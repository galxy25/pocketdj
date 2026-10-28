
## Wave 1
Merged (clean, no conflicts): SURF-1, GM-2, MIX-0, BRW-1, COL-1, SVC-12. Tests: 626 run, 0 failures (count moved from ~275 baseline).
Emulator (emulator-5554, shots in pocketdj-parity/_shots/wave1/):
- SURF-1: PASS launch lands on History; 7 destinations, label only on selected; Collections restored after force-stop; Games placeholder opens. NOT verified: rail layout (wm size 1280x800 is only ~488dp at 420dpi so stays bottom bar; needs wm density change), staged-push route, Settings block order.
- COL-1: Collections screen lists playlists/pockets; fixture adb-push step not run.
- SVC-12, BRW-1: emulator steps not run (timing logs / filter UI).
- GM-2, MIX-0: pure JVM, pass.
No FATAL/ANR in logcat.
Open issues: nav label "Collections" truncates to "Collecti" at 411dp; amPlaylistId persistence decision (COL-1); amrec_album_ preview fallback deferred (SURF-1); Browse must consume NavRequestBus.pendingBrowseQuery; 13 screens still collect full catalog state (SVC-12 partial).
