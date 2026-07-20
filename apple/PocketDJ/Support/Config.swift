import Foundation

/// Backend endpoints — identical to the ones the PWA uses, so web and native
/// stay in sync. The catalog + art are origin-relative on the web (served by
/// CloudFront); here we resolve those relative paths against `catalogBase`.
enum Config {
    enum Environment { case dev, prod }

    /// Flip to `.prod` to point at the production CloudFront distribution.
    static var environment: Environment = .dev

    /// CloudFront site that serves `current-index.json` and `/art/…`.
    static var catalogBase: URL {
        switch environment {
        case .dev:  return URL(string: "https://djictbz9w796r.cloudfront.net")!
        case .prod: return URL(string: "https://d2p4cubg6se03u.cloudfront.net")!
        }
    }

    /// Public S3 rips bucket: `rips/manifest.json` + `rips/<songId>.mp3`.
    static let ripsBase = URL(string: "https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com")!

    /// iMac rip server (rip-on-demand + live HLS + Discover search). PUBLIC since the
    /// beta-distribution promotion: Tailscale Funnel serves it on HTTPS port 10000
    /// (scripts/setup-rip-funnel.sh), so beta testers off the Tailnet reach it too —
    /// with a bearer token once the funnel script provisions them (Settings ▸ Rip
    /// server ▸ token; RIP_TOKEN user tier, RIP_ADMIN_TOKEN admin tier). Port note:
    /// 443 stays the Tailnet-only `tailscale serve` mount (Levi's original path) and
    /// 8443 is the jukebox Funnel — Funnel is per-PORT, so the rip server rides the
    /// third HTTPS port.
    static let ripServerBase = URL(string: "https://levis-imac.tail2e2bdf.ts.net:10000")!

    /// Jukebox Hero session broker (scripts/jukebox-server.mjs). PUBLICLY reachable —
    /// guests submit requests from their own phones — via Tailscale Funnel at the
    /// `:8443/jukebox` path mount (the first public mount; the rip server followed on
    /// :10000). Port 8443 (not 443) is load-bearing: Funnel is per-PORT and 443 stays
    /// the Tailnet-only `tailscale serve` rip-server mount. (The planned Lambda + API
    /// Gateway move changes only this base URL.)
    static let jukeboxServerBase = URL(string: "https://levis-imac.tail2e2bdf.ts.net:8443/jukebox")!

    /// The catalog index document (vinyl, the default source).
    static var indexURL: URL { catalogBase.appendingPathComponent("current-index.json") }

    /// Opt-in "Apple Music (Local)" source — the deployed Library.xml index.
    static var appleMusicIndexURL: URL { catalogBase.appendingPathComponent("apple-music-index.json") }
    static let appleMusicSourceName = "Apple Music (Local)"

    /// Opt-in "My Digital" source — raw on-disk/S3 audio files indexed + transcoded by
    /// `scripts/index-digital-files.mjs` (pre-ripped to the rips bucket, so they stream/burn
    /// with no rip step). Published alongside the other catalogs on CloudFront.
    static var digitalIndexURL: URL { catalogBase.appendingPathComponent("digital-index.json") }
    static let digitalSourceName = "My Digital"

    /// The OWNER allowlist for two-way Apple Music favorites — salted SHA-256 of the
    /// iCloud user-record name (see `OwnerIdentity`). **Ships EMPTY on purpose**: an empty
    /// set means nobody is the owner, so every install is favorites-local-only, which is
    /// the safe default. To enable it, read your hash from Settings ▸ Debug ▸ "Owner
    /// identity" and paste it below.
    ///
    /// Add BOTH environments' hashes. `CKContainer.userRecordID` is container-scoped, so
    /// the CloudKit Development and Production containers yield DIFFERENT values — with
    /// only the dev hash a TestFlight build silently falls back to local-only.
    static let ownerICloudHashes: Set<String> = [
        // "…dev container hash…",
        // "…prod container hash…",
    ]

    /// A NEW profile's starting favorites — a snapshot of the owner's APPLE MUSIC ♥,
    /// applied once (per `version`) on a tester's first run. Apple-Music-sourced ids only:
    /// the owner's vinyl / My Digital favorites are personal and never ship here.
    /// Produced by the owner-only "Export favorites seed" action in Settings ▸ Debug.
    static var favoritesSeedURL: URL { catalogBase.appendingPathComponent("favorites-seed.json") }

    /// ONLINE-search host config (`{ host, region, index }`), served by the same
    /// CloudFront. Read at launch so the aoss collection can be swapped (e.g. a
    /// scale-to-zero rebuild → new host) WITHOUT shipping a new client build.
    static var searchConfigURL: URL { catalogBase.appendingPathComponent("search-config.json") }

    /// Studio ▸ Instruments pack index (`{version, attribution, sharedBanks, packs}`),
    /// listing the downloadable SoundFont banks. Lives on the public rips bucket — the
    /// bucket policy only makes `rips/*` public, so packs MUST stay under that prefix.
    static var instrumentsIndexURL: URL { ripsBase.appendingPathComponent("rips/instruments/index.json") }

    /// Base for instrument-pack keys relative to the index (e.g. `banks/<file>.sf2` →
    /// `rips/instruments/banks/<file>.sf2`). Sibling of `instrumentsIndexURL`.
    static var instrumentsBase: URL { ripsBase.appendingPathComponent("rips/instruments") }

    /// Resolve an art URL that may be root-relative (`/art/<albumId>.jpg`, the
    /// mirrored thumbnail served by the same CloudFront) or already absolute
    /// (e.g. an iTunes `mzstatic` cover).
    static func artURL(_ raw: String) -> URL? {
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: catalogBase)?.absoluteURL
        }
        return URL(string: raw)
    }
}
