import XCTest

// DEVICE-DRIVE (opt-in): retry the Apple Music library write for provisional New-tile
// albums whose original write failed silently, ON THE REAL DEVICE, against the user's
// REAL catalog and Apple Music account — and report each album's outcome from what the
// UI actually shows (the `album-am-retry` surface from the 8ad21059/28fba690 fix).
//
// This is NOT a fixture test:
//   • it launches WITHOUT `PDJ_USE_FIXTURE`, so real UserDefaults + the real
//     Application Support stores (discover-adds, debug sessions) are in play;
//   • it skips entirely unless `PDJ_AM_RETRY_DEVICE=1` reaches the runner
//     (pass `TEST_RUNNER_PDJ_AM_RETRY_DEVICE=1` to xcodebuild), the same opt-in
//     shape as MacTreeDumpUITests' PDJ_DUMP_DIR — a normal suite pays nothing.
//
// Reporting contract: every album emits exactly one machine-parseable line
//     PDJRESULT | <album> | <outcome> | <detail>
// via print + NSLog + a kept XCTAttachment, and NO album hard-fails the run for the
// others (continueAfterFailure + per-album XCTContext.runActivity). Outcomes:
//     healed-now / already-healed / still-failing / blocked / no-retry-surface
//
// The run also brackets the retries with Settings ▸ Debug capture ON→OFF, so the app's
// `amwrite …` route lines (native MPErrorDomain throw → web API POST → HTTP status) are
// frozen into Application Support/pocketdj-debug-sessions/ for a post-run devicectl pull.
//
// The device can auto-lock mid-run: every stage launches the app fresh and, when the app
// never reaches the foreground, reports "blocked … device likely locked" plainly instead
// of a phantom failure.

#if !os(macOS)
final class AMWriteRetryDeviceUITests: XCTestCase {

    private struct Target {
        let title: String        // exact album title, for the report
        let artist: String       // search query (artists are distinctive; titles have "- EP" noise)
        let cardFragment: String // substring of the album card's label that pins the right card
    }

    /// Levi's four silently-failed New-tile adds (2026-08). Legacy entries — recorded
    /// before write outcomes were tracked — so `needsRetry` shows the button even with
    /// no failure note.
    private let targets: [Target] = [
        .init(title: "Summer of Love", artist: "Teddy Pendergrass", cardFragment: "Summer of Love"),
        .init(title: "Paradise - EP", artist: "Elaquent", cardFragment: "Paradise"),
        .init(title: "Whatchu Bringing?", artist: "Dinner Party", cardFragment: "Whatchu Bringing"),
        .init(title: "LIMBO - EP", artist: "Arin Ray", cardFragment: "LIMBO"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipIf(ProcessInfo.processInfo.environment["PDJ_AM_RETRY_DEVICE"] == nil,
                      "real-device AM write retry drive — set TEST_RUNNER_PDJ_AM_RETRY_DEVICE=1 to run")
    }

    // MARK: reporting

    private func report(_ album: String, _ outcome: String, _ detail: String) {
        let flat = detail.replacingOccurrences(of: "\n", with: " ⏎ ")
        let line = "PDJRESULT | \(album) | \(outcome) | \(flat)"
        print(line)
        NSLog("%@", line)
        let att = XCTAttachment(string: line)
        att.name = "PDJRESULT-\(album)"
        att.lifetime = .keepAlways
        add(att)
    }

    // MARK: stages

    /// Fresh launch per stage (re-foregrounds after a possible auto-lock). Real state:
    /// no fixture env — only the landing-section seam.
    private func freshApp(section: String) -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchEnvironment["PDJ_START_SECTION"] = section
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 30) else { return nil }
        return app
    }

    /// Clear whatever is in the Browse search field and type `text` (then Return, which
    /// also dismisses the keyboard so result cards are tappable).
    private func search(_ app: XCUIApplication, _ text: String) -> Bool {
        var field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 10) {
            app.swipeDown()   // iPhone can tuck the searchable field under the nav title
            field = app.searchFields.firstMatch
            guard field.waitForExistence(timeout: 10) else { return false }
        }
        field.tap()
        if let v = field.value as? String, !v.isEmpty, !v.hasPrefix("Search") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
        }
        field.typeText(text + "\n")
        return true
    }

    /// Settings ▸ Debug ▸ "Capture debug log". ON before the retries, OFF after — the
    /// OFF freezes the session into Application Support/pocketdj-debug-sessions/ where
    /// the host pulls the `amwrite` route lines via devicectl. Best-effort: a failure
    /// here reports and moves on, it never blocks the retries themselves.
    private func setDebugCapture(_ on: Bool) {
        XCTContext.runActivity(named: "debug capture \(on ? "ON" : "OFF")") { _ in
            guard let app = freshApp(section: "Settings") else {
                report("debug-capture", "blocked",
                       "app never reached foreground for Settings — device likely locked")
                return
            }
            let row = app.buttons["settings-debug"]
            if !row.waitForExistence(timeout: 20) || !row.isHittable {
                guard app.swipeTo(row) else {
                    report("debug-capture", "blocked", "settings-debug row never appeared")
                    return
                }
            }
            row.tap()
            let toggle = app.switches["debug-capture-toggle"].firstMatch
            guard toggle.waitForExistence(timeout: 15) else {
                report("debug-capture", "blocked", "debug-capture-toggle never appeared")
                return
            }
            toggle.setToggled(on)   // Form-toggle tap trap handled by the helper
            Thread.sleep(forTimeInterval: 1)
            report("debug-capture", "set",
                   "capture=\(on) toggleValue=\(String(describing: toggle.value))")
        }
    }

    /// Search out the album, open its detail, and drive the retry surface to a verdict.
    private func driveAlbum(_ t: Target) {
        guard let app = freshApp(section: "Browser") else {
            report(t.title, "blocked", "app never reached foreground — device likely locked")
            return
        }
        // Browse ▸ Albums. "Albums" is ambiguous with Discover's scope picker; the kind
        // segment is boundBy 0 (same disambiguation as DiscoverAlbumPreviewUITests).
        let albumsKind = app.buttons.matching(identifier: "Albums").element(boundBy: 0)
        guard albumsKind.waitForExistence(timeout: 30) else {
            report(t.title, "blocked", "Browse kind picker never appeared")
            return
        }
        albumsKind.tap()
        guard search(app, t.artist) else {
            report(t.title, "blocked", "Browse search field never appeared")
            return
        }

        // The provisional New-tile albums carry amrec ids — prefer those cards so a
        // same-named real (AM-synced) album can't swallow the tap; fall back to any
        // album card whose label carries the title (excluding the header's own
        // album-am-* ids, which are absent on the results screen anyway).
        let amrec = NSPredicate(format:
            "identifier BEGINSWITH 'album-amrec_album_' AND label CONTAINS[c] %@", t.cardFragment)
        let any = NSPredicate(format:
            "identifier BEGINSWITH 'album-' AND NOT (identifier BEGINSWITH 'album-am-') AND label CONTAINS[c] %@",
            t.cardFragment)
        var card = app.descendants(matching: .any).matching(amrec).firstMatch
        if !card.waitForExistence(timeout: 20) {
            card = app.descendants(matching: .any).matching(any).firstMatch
            guard card.waitForExistence(timeout: 10) else {
                report(t.title, "blocked",
                       "no album card matching “\(t.cardFragment)” after searching “\(t.artist)”")
                return
            }
        }
        if !card.isHittable { _ = app.swipeTo(card) }
        let cardId = card.identifier
        card.tap()
        guard app.any("album-detail").waitForExistence(timeout: 20) else {
            report(t.title, "blocked", "album detail never opened (card \(cardId))")
            return
        }

        let confirmed = app.any("album-am-confirmed")
        let retry = app.buttons["album-am-retry"].firstMatch
        let note = app.any("album-am-note")

        // Pre-state: a proven write means someone already healed it.
        if confirmed.waitForExistence(timeout: 8) {
            report(t.title, "already-healed",
                   "header already reads “In your Apple Music library” (card \(cardId))")
            return
        }
        guard retry.waitForExistence(timeout: 10) else {
            report(t.title, "no-retry-surface",
                   "neither retry button nor confirmed header on \(cardId) — "
                   + "is Apple Music capability available on this profile?")
            return
        }
        let preNote = note.exists ? note.visibleText : "(no failure note shown — legacy entry)"

        retry.tap()

        // Terminal states: the confirmed header (success), or the button back to
        // "Add to Apple Music again" after an in-flight phase / a changed failure note.
        var sawInFlight = false
        var outcome = "still-failing"
        var terminal = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if confirmed.exists { outcome = "healed-now"; terminal = true; break }
            if retry.exists {
                let label = retry.label
                if label.contains("Adding to Apple Music") { sawInFlight = true }
                else if sawInFlight, label.contains("again"), retry.isEnabled {
                    terminal = true; break
                }
            }
            if !sawInFlight, note.exists, note.visibleText != preNote,
               !(note.visibleText.isEmpty) {
                terminal = true; break   // failed fast enough that we never saw the spinner
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if !terminal { outcome = "still-failing" }

        let postNote: String
        if confirmed.exists {
            postNote = "In your Apple Music library"
        } else if note.exists {
            postNote = note.visibleText
        } else {
            postNote = terminal ? "(no failure note visible)" : "(timed out after 30s — no terminal state)"
        }
        report(t.title, outcome, "pre: \(preNote) → post: \(postNote)")
    }

    // MARK: the drive

    func testRetryFailedAppleMusicAlbumWrites() {
        setDebugCapture(true)
        for t in targets {
            XCTContext.runActivity(named: "Album — \(t.title) (\(t.artist))") { _ in
                driveAlbum(t)
            }
        }
        setDebugCapture(false)
    }
}
#endif
