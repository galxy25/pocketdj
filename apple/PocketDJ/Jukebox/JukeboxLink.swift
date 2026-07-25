import Foundation

/// A parsed jukebox deep-link — the shared shape of the two ways a shared link opens the app
/// (Feature: join an in-progress jukebox from a link). BOTH forms are supported (Levi 2026-07-25):
///   • Universal Link:  `https://jukebox.pocket-dj.com/<id>/`   (the guest page URL / QR payload)
///   • Custom scheme:   `pocketdj://jukebox/<id>`                (fallback when the app is installed
///                                                                but the universal link doesn't fire)
/// Both carry only the jukebox id — the session is public today, so the id is the whole capability
/// (see the JukeboxModels `#TOUPDATE` notes on the missing guest token). A device opening a link
/// joins as a CLIENT (native guest): it reads the public `state.json` and posts requests. Only the
/// device that STARTED the jukebox holds the `hostKey` and is the lead — a link never confers it.
struct JukeboxLink: Equatable {
    let jukeboxId: String
    /// The https guest origin (e.g. `https://jukebox.pocket-dj.com`) when the link was a universal
    /// link; nil for a `pocketdj://` link (which carries no origin). Used to read
    /// `<guestBase>/<id>/state.json`; a nil base falls back to the canonical host.
    let guestBase: URL?

    /// The custom URL scheme the app registers (paired with the universal link).
    static let scheme = "pocketdj"
    /// The universal-link host the app claims via `applinks:` associated-domains.
    static let universalHost = "jukebox.pocket-dj.com"
    /// The base32 alphabet the server mints session ids from (`genId`, jukebox-server.mjs).
    private static let idAlphabet = "abcdefghijklmnopqrstuvwxyz234567"

    /// Parse a deep-link URL into a `JukeboxLink`, or nil if it isn't a jukebox link. Accepts:
    ///   `pocketdj://jukebox/<id>`              (custom scheme; tolerates `pocketdj:///jukebox/<id>`)
    ///   `https://jukebox.pocket-dj.com/<id>/`  (+ optional trailing `state.json` / path)
    /// The id must match the server's shape (`[a-z2-7]{4,32}`, 8 chars today) so an unrelated URL
    /// (an OAuth redirect, a `.pdjcollection` file) is never misread as a jukebox link.
    init?(url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (comps?.scheme ?? url.scheme ?? "").lowercased()
        let host = (comps?.host ?? url.host ?? "").lowercased()
        // Non-empty path segments (drops the leading "/" and any empty/trailing slashes).
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        switch scheme {
        case JukeboxLink.scheme:
            // pocketdj://jukebox/<id>  → host "jukebox", id is the first path segment.
            // pocketdj:///jukebox/<id> → host empty, "jukebox" + id both in the path.
            var parts = segments
            if host == "jukebox" {
                // id is parts.first
            } else if parts.first?.lowercased() == "jukebox" {
                parts.removeFirst()
            } else {
                return nil
            }
            guard let id = parts.first, JukeboxLink.isValidId(id) else { return nil }
            jukeboxId = id
            guestBase = nil

        case "https", "http":
            guard host == JukeboxLink.universalHost, let id = segments.first,
                  JukeboxLink.isValidId(id) else { return nil }
            jukeboxId = id
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

    /// The public guest `state.json` URL to poll: `<guestBase>/<id>/state.json`. Falls back to the
    /// canonical host when the link carried no origin (custom scheme).
    var stateURL: URL? {
        let base = guestBase ?? URL(string: "https://\(JukeboxLink.universalHost)")
        return base?
            .appendingPathComponent(jukeboxId)
            .appendingPathComponent("state.json")
    }
}
