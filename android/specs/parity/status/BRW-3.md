state: implemented

BRW-3 Explicit/edition system.
- [x] IndexModels: url fields, edition ids, dateAdded, IndexArtist + IndexJson.artists, IndexSong.appleMusicId(edition)
- [x] SongVariant, EditionPolicy, CleanOnly, EditionSettings (tri-state string pref)
- [x] EditionSection registered via BrowseGraph.settingsSections (order 450)
- [x] PlayResolver.resolveForEdition (edition pick before resolve)
- [x] Tests: EditionPolicyTest (15), IndexModelsAdditiveFieldsTest (5), PlayResolverEditionTest (4)

Notes: PlaybackController is not wired to resolveForEdition (not an owned file); hook is ready for it.
Tests added: 24. Total after: 650.
