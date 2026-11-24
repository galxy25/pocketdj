state: in-progress

# P2-MM-2 Mix Mode ph1b: expiry sweep, soft-cap order, triggers, SAF identity

- [x] TemporarySweep.kt (pure plan, identity, ticker), StorageManager.sweepTemporary*, prune temp-first order
- [x] BurnStore.removeTemporaryAssets, picked-folder identity = tree uri
- [x] Triggers wired (app foreground/launch, hourly tick, prune job, cap/disk guard entry points)
- [ ] Tests green + assembleDebug
