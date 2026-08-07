import Foundation

/// A parsed Music with Friends deep-link — the JukeboxLink shape for `/mwf/<id>` URLs:
///   • Universal Link:  `https://jukebox.pocket-dj.com/mwf/<id>/`  (the landing page / QR payload)
///   • Custom scheme:   `pocketdj://mwf/<id>`
/// The literal first segment `mwf` is what separates these from jukebox links — and it can
/// NEVER collide with a jukebox session id (`[a-z2-7]{4,32}`; "mwf" is 3 chars, so
/// `JukeboxLink` rejects `/mwf/...` URLs and this parser rejects bare `/<id>/` ones).
struct MwFLink: Equatable {
    let sessionId: String
    /// The https origin when the link was a universal link; nil for `pocketdj://`.
    let guestBase: URL?

    static let scheme = "pocketdj"
    static let universalHost = "jukebox.pocket-dj.com"
    private static let idAlphabet = "abcdefghijklmnopqrstuvwxyz234567"

    /// Parse a deep-link URL, or nil if it isn't an MwF link. Accepts:
    ///   `pocketdj://mwf/<id>`              (host "mwf"; tolerates `pocketdj:///mwf/<id>`)
    ///   `https://jukebox.pocket-dj.com/mwf/<id>/` (+ optional trailing path)
    init?(url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (comps?.scheme ?? url.scheme ?? "").lowercased()
        let host = (comps?.host ?? url.host ?? "").lowercased()
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        switch scheme {
        case MwFLink.scheme:
            var parts = segments
            if host == "mwf" {
                // id is parts.first
            } else if parts.first?.lowercased() == "mwf" {
                parts.removeFirst()
            } else {
                return nil
            }
            guard let id = parts.first, MwFLink.isValidId(id) else { return nil }
            sessionId = id
            guestBase = nil

        case "https", "http":
            guard host == MwFLink.universalHost,
                  segments.first?.lowercased() == "mwf",
                  segments.count >= 2, MwFLink.isValidId(segments[1]) else { return nil }
            sessionId = segments[1]
            var c = URLComponents()
            c.scheme = "https"
            c.host = host
            guestBase = c.url

        default:
            return nil
        }
    }

    /// The server's session-id shape: base32 `[a-z2-7]`, 4–32 chars (8 today).
    static func isValidId(_ s: String) -> Bool {
        (4...32).contains(s.count) && s.allSatisfy { idAlphabet.contains($0) }
    }

    /// The public `state.json` URL: `<base>/mwf/<id>/state.json` (canonical host fallback).
    var stateURL: URL? {
        let base = guestBase ?? URL(string: "https://\(MwFLink.universalHost)")
        return base?
            .appendingPathComponent("mwf")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("state.json")
    }
}
