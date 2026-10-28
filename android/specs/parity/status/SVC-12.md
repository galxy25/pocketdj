state: implemented

- [x] CatalogService.load(url, seed): 304/error/network failure with seed returns seed identity, changed=false
- [x] CatalogRepository: skips merge when all inputs identical by identity; catalog instance unchanged; mergeCount seam
- [x] COMPILED_IN switched to green (pinned to config/endpoints.green.json by EndpointsGreenPinTest); legacy blue catalog hosts still rebase
- [x] Tests: CatalogCacheTest (6), EndpointsGreenPinTest (4); removed blue-pin test from RemoteEndpointsTest (superseded)

Deviations: no separate CatalogServiceTest/CatalogRepositoryTest additions; all in CatalogCacheTest. Json-counting fake impossible (Json is abstract class); proved no-decode by corrupting disk cache.

## Review
- MINOR StateFlow emits on unchanged refresh -> fixed (partial by design): added `CatalogRepository.catalogFlow` (distinct by instance) for screens; the full `state` still flips isRefreshing. Migrating the 13 screens to `catalogFlow` is follow-up; criterion is PARTIAL for existing collectors.
- MINOR no warm-cache cold-launch test -> fixed: `coldLaunchWithWarmCacheSeedsOnceAndSkipsMergeOn304` (mergeCount==1, If-None-Match sent, instance stable).
- MINOR fixed sleeps in tests -> fixed: deterministic `refreshCompletions` counter + `awaitCompletions`; removed waitIdle/sleeps.
- MINOR emulator timing unverified -> partial: added `CatalogTiming` logcat lines (seed ready / refresh complete); emulator run left to integrator (not allowed here).
- NIT Loaded.changed iOS divergence -> fixed: no-seed 304 / failure cache-fallback now changed=false; test renamed.
- NIT seed hides refresh error -> rejected: non-destructive behaviour intended; optional.

fixes applied
Tests: 285 run, 0 failures (CatalogCacheTest 7).
