state: in-progress

# P2-POC-10: Moment card + History Pockets Wheel|List + List Play = derived run

- [x] ParityFlags.POCKET_WHEEL flipped to true
- [x] PocketsTabGate.tabVisible(historyNonEmpty) + PocketsSegment (default Wheel, pref pdj.history.pockets.segment, List hidden when declined)
- [x] PocketMomentCard (+ PocketCardText pure helpers), sheet on phones / side pane >= 600 dp
- [x] PocketsTabScreen (segment, wheel host, finished card with "another pocket")
- [x] List detail Play -> PocketRunStore.start(fromListening), notes, "Play the original songs" (pocket-replay)
- [x] Tests
- [ ] Build/test green
