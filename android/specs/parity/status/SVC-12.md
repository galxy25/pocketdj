state: implemented

- [x] CatalogService.load(url, seed): 304/error/network failure with seed returns seed identity, changed=false
- [x] CatalogRepository: skips merge when all inputs identical by identity; catalog instance unchanged; mergeCount seam
- [x] COMPILED_IN switched to green (pinned to config/endpoints.green.json by EndpointsGreenPinTest); legacy blue catalog hosts still rebase
- [x] Tests: CatalogCacheTest (6), EndpointsGreenPinTest (4); removed blue-pin test from RemoteEndpointsTest (superseded)

Deviations: no separate CatalogServiceTest/CatalogRepositoryTest additions; all in CatalogCacheTest. Json-counting fake impossible (Json is abstract class); proved no-decode by corrupting disk cache.
