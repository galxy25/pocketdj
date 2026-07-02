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

    /// iMac rip server exposed over Tailscale (rip-on-demand + live HLS). Tailnet-only.
    static let ripServerBase = URL(string: "https://levis-imac.tail2e2bdf.ts.net")!

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

    /// ONLINE-search host config (`{ host, region, index }`), served by the same
    /// CloudFront. Read at launch so the aoss collection can be swapped (e.g. a
    /// scale-to-zero rebuild → new host) WITHOUT shipping a new client build.
    static var searchConfigURL: URL { catalogBase.appendingPathComponent("search-config.json") }

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
