state: implemented

# ANS-GAP-5 - Storage soft-cap prune + yieldBackgroundDownload

- [x] Soft-cap prune: StorageManager (LRP, protected sets, stamp-first, one-scan plan, chunked async on IO), foreground + WorkManager triggers were ALREADY present from SVC-6 (ledger row SURF-2 text was stale). Added end-to-end StorageSoftCapTest (real BurnStore + planner + files).
- [x] BurnStore.yieldBackgroundDownload (cancels a pending `.downloading` background transfer, drops row; no-op without transfers); BurnStoreAdopter default now calls it, so MixStreamLoader.open() yields. TODO(SVC-3) removed.
- [x] Tests: StorageSoftCapTest (3), BurnStoreYieldTest (3). Suite 5492 tests, 0 failures; assembleDebug green.

Files touched: BurnStore.kt, MixStreamLoader.kt (BurnStoreAdopter default; minimal, additive). No MixGraph change needed.
Emulator step (cap below usage, cold start) not run (emulator is integrator-owned).
