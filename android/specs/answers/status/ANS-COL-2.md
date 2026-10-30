state: in-progress

# ANS-COL-2: Collection activity batch cap

- [x] recordAll keeps newest maxEvents/4 of one batch (iOS maxBatchContribution parity)
- [x] Tests: 10k batch keeps newest 5k and preserves prior history; 153-song batch = 153 rows
- [ ] gradle green at tip

Documented for Levi: selection stays armed after Add-to, and one activity row per song - both already match iOS; no change made.
Files touched: only owned files (CollectionActivityStore.kt, CollectionActivityStoreTest.kt).
Note: local Gradle needed -Xmx6g + in-process Kotlin compile (machine memory pressure); gradle.properties not changed.
