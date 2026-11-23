state: implemented

# P2-DATA-1: durable session snapshot passthrough

- [x] Typed optional DTOs: npMixMode, fxLock (effects map, raw keys), djMode (planner raw JsonObject), Row.plan/appleMusicId/djUserNext/djPlaced
- [x] Unknown-key passthrough (top-level, row, plan, npMixMode, fxLock, per-effect, djMode) via SnapshotCodec; schemaVersion stays 1
- [x] PlaybackSessionStore.extras / updateExtras (SnapshotExtras); save() overlays carried fields onto rebuilt snapshots
- [x] Tests: SessionSnapshotPassthroughTest (9 new), iOS 1.0.6 fixture. Suite total 5789, 0 failures; assembleDebug + assembleRelease green.

## Deviations
- SnapshotExtras.kt also holds the DTOs and codec (owned file, no extra files).
- Row-level iOS fields (plan/appleMusicId/djUserNext) are carried through decode/encode, but a row rebuilt by SessionSnapshot.row(QueueItem) from the sequencer does not yet carry them (QueueItem has no such fields; later packages P2-POC/P2-DJ own that). Top-level fields are carried by the store.
- Kotlin prints large Doubles as 7.89E11 (pre-existing); fixture uses that form.

## Questions for Levi
None.
