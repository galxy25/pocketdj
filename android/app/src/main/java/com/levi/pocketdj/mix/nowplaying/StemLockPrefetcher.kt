package com.levi.pocketdj.mix.nowplaying

/**
 * The lane was born as the Stem Lock's prefetcher; it is now [NowPlayingPrefetcher] (one lane for
 * everything). Kotlin cannot reach nested classes through a typealias: use `NowPlayingPrefetcher.Step` /
 * `.Track` / `.Plan` and the top-level [NetworkClass]. With Mix Mode off, `plan(...)` is the Stem Lock plan.
 */
typealias StemLockPrefetcher = NowPlayingPrefetcher
