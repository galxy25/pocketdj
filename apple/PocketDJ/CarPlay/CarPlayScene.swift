#if os(iOS)
import CarPlay
import UIKit

/// CarPlay scene entry point. Declared as the CarPlay scene's delegate in the Info.plist
/// UIApplicationSceneManifest (see project.yml). SwiftUI keeps owning the phone's window scene;
/// this owns the head-unit templates. It reaches the SAME app-scoped stores as the phone UI
/// through `IntentServices.shared` (a separate `UIScene` gets no SwiftUI environment) — never
/// its own stores, which would fork a second catalog/mix graph.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let controller = CarPlayController(interfaceController: interfaceController)
        self.controller = controller
        controller.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller = nil
    }
}

/// Builds + drives the CarPlay template hierarchy from `CarPlayModel`.
/// Root = a tab bar: Playlists · Pockets · Albums · Search. Collections drill into their songs
/// (with a "Play all" row); a song opens an action sheet (Play now / Add to…). Everything plays
/// through the shared sequencer, so the head unit's Now Playing matches the phone.
@MainActor
final class CarPlayController {
    private let interfaceController: CPInterfaceController
    private var model: CarPlayModel?
    /// Tiny artwork cache (albumId → image) so re-browsing doesn't refetch.
    private var artCache: [String: UIImage] = [:]
    /// The currently-pushed Up Next list, kept so an edit can refresh it in place.
    private var upNextTemplate: CPListTemplate?
    private lazy var nowPlayingObserver = CarPlayNowPlayingObserver(controller: self)

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        // A brief loading root until the catalog is warm, then the real tab bar.
        let loading = CPListTemplate(title: "PocketDJ", sections: [
            CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
        ])
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        Task { await buildRoot() }
    }

    private func buildRoot() async {
        guard let services = IntentServices.shared else { return }
        let model = CarPlayModel(services: services)
        self.model = model
        await model.ensureReady()

        let playlists = listTemplate(title: "Playlists", tabImageName: "music.note.list",
                                     rows: model.playlists()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inPlaylist: row.id),
                            playAll: { await model.playPlaylist(id: row.id) },
                            shuffleAll: { await model.playPlaylist(id: row.id, shuffle: true) })
        }
        let pockets = listTemplate(title: "Pockets", tabImageName: "square.stack.fill",
                                   rows: model.pockets()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inPocket: row.id),
                            playAll: { await model.playPocket(id: row.id) },
                            shuffleAll: { await model.playPocket(id: row.id, shuffle: true) })
        }
        let albums = albumsTemplate(model)
        let artists = artistsTemplate(model)

        // No free-text Search tab: CarPlay keyboard entry is blocked while driving (it froze the
        // app on a real head unit). Finding without a keyboard is the A–Z index on Albums / Artists.
        let tabBar = CPTabBarTemplate(templates: [playlists, pockets, albums, artists])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
        configureNowPlaying()
    }

    /// The shared Now Playing template is reachable via the system Now Playing button once audio is
    /// playing (that's why we set MPNowPlayingInfoCenter.playbackState in the engines). Enable its
    /// "Up Next" button and observe taps so the driver can see + edit the upcoming queue.
    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.isUpNextButtonEnabled = true
        np.add(nowPlayingObserver)
    }

    // MARK: - List templates

    /// Build a browsable list template from rows; `onSelect` handles a row tap (drill-in).
    /// Tabs always use an SF Symbol `tabImage` (+ `tabTitle`) — NOT `tabSystemItem`, whose fixed
    /// system icon/label would override them (e.g. a `.more` item renders a misleading "•••").
    private func listTemplate(title: String, tabImageName: String, rows: [CarPlayModel.Row],
                              onSelect: @escaping (CarPlayModel.Row) -> Void) -> CPListTemplate {
        let items = rows.map { row -> CPListItem in listItem(row, showsDisclosure: true) { onSelect(row) } }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: tabImageName)
        template.tabTitle = title
        return template
    }

    /// A tab grouped into A–Z sections with a `sectionIndexTitle` on each so the head unit shows the
    /// alphabet quick-scroll — the keyboard-free way to "find" while driving (Albums, Artists).
    private func azListTemplate(title: String, tabImageName: String, emptyText: String,
                                rows: [CarPlayModel.Row],
                                onSelect: @escaping (CarPlayModel.Row) -> Void) -> CPListTemplate {
        let sorted = rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var sections: [CPListSection] = []
        for row in sorted {
            let letter = Self.indexLetter(row.title)
            let item = listItem(row, showsDisclosure: true) { onSelect(row) }
            if let last = sections.last, last.sectionIndexTitle == letter {
                sections[sections.count - 1] = CPListSection(items: last.items + [item],
                                                             header: nil, sectionIndexTitle: letter)
            } else {
                sections.append(CPListSection(items: [item], header: nil, sectionIndexTitle: letter))
            }
        }
        let template = CPListTemplate(title: title, sections: sections.isEmpty
            ? [CPListSection(items: [CPListItem(text: emptyText, detailText: nil)])] : sections)
        template.tabImage = UIImage(systemName: tabImageName)
        template.tabTitle = title
        return template
    }

    private func albumsTemplate(_ model: CarPlayModel) -> CPListTemplate {
        azListTemplate(title: "Albums", tabImageName: "opticaldisc", emptyText: "No albums",
                       rows: model.albums()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inAlbum: row.id),
                            playAll: { await model.playAlbum(id: row.id) },
                            shuffleAll: { await model.playAlbum(id: row.id, shuffle: true) })
        }
    }

    private func artistsTemplate(_ model: CarPlayModel) -> CPListTemplate {
        azListTemplate(title: "Artists", tabImageName: "music.mic", emptyText: "No artists",
                       rows: model.artists()) { [weak self] row in
            self?.pushArtistAlbums(name: row.title, model: model)   // row.title == artist name
        }
    }

    /// An artist's albums, with Play all / Shuffle all (the whole discography) on top.
    private func pushArtistAlbums(name: String, model: CarPlayModel) {
        let playAll = CPListItem(text: "▶ Play all", detailText: nil)
        playAll.handler = { [weak self] _, c in Task { await model.playArtist(name: name); self?.showNowPlaying(); c() } }
        let shuffle = CPListItem(text: "🔀 Shuffle all", detailText: nil)
        shuffle.handler = { [weak self] _, c in Task { await model.playArtist(name: name, shuffle: true); self?.showNowPlaying(); c() } }
        let albums = model.albums(byArtist: name).map { album in
            listItem(album, showsDisclosure: true) { [weak self] in
                self?.pushSongs(title: album.title, rows: model.songs(inAlbum: album.id),
                                playAll: { await model.playAlbum(id: album.id) },
                                shuffleAll: { await model.playAlbum(id: album.id, shuffle: true) })
            }
        }
        let template = CPListTemplate(title: name, sections: [
            CPListSection(items: [playAll, shuffle]),
            CPListSection(items: albums.isEmpty ? [CPListItem(text: "No albums", detailText: nil)] : albums,
                          header: "Albums", sectionIndexTitle: nil),
        ])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// First-letter index key: A–Z, else "#".
    private static func indexLetter(_ s: String) -> String {
        guard let c = s.trimmingCharacters(in: .whitespaces).first?.uppercased(),
              c.range(of: "^[A-Z]$", options: .regularExpression) != nil else { return "#" }
        return c
    }

    /// Drill into a collection's songs, with "Play all" + "Shuffle all" rows on top; a song opens
    /// the action sheet.
    private func pushSongs(title: String, rows: [CarPlayModel.Row],
                           playAll: @escaping () async -> Void, shuffleAll: @escaping () async -> Void) {
        var sections: [CPListSection] = []
        if !rows.isEmpty {
            let playAllItem = CPListItem(text: "▶ Play all", detailText: nil)
            playAllItem.handler = { [weak self] _, completion in
                Task { await playAll(); self?.showNowPlaying(); completion() }
            }
            let shuffleItem = CPListItem(text: "🔀 Shuffle all", detailText: nil)
            shuffleItem.handler = { [weak self] _, completion in
                Task { await shuffleAll(); self?.showNowPlaying(); completion() }
            }
            sections.append(CPListSection(items: [playAllItem, shuffleItem]))
        }
        let songItems = rows.map { row -> CPListItem in
            listItem(row, showsDisclosure: false) { [weak self] in self?.presentSongActions(row) }
        }
        sections.append(CPListSection(items: songItems.isEmpty
            ? [CPListItem(text: "No songs", detailText: nil)] : songItems, header: "Songs", sectionIndexTitle: nil))
        let template = CPListTemplate(title: title, sections: sections)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// A song tap → an action sheet: Play now, Add to…, Cancel (CarPlay has no row context menu).
    private func presentSongActions(_ row: CarPlayModel.Row) {
        guard let model else { return }
        let play = CPAlertAction(title: "Play now", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            Task { await model.playSong(id: row.id); self?.showNowPlaying() }
        }
        let add = CPAlertAction(title: "Add to pocket / playlist", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true) { _, _ in
                self?.pushAddTargets(for: row)
            }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let sheet = CPActionSheetTemplate(title: row.title, message: row.subtitle, actions: [play, add, cancel])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// Push the list of add-to destinations; selecting one adds the song and pops back.
    private func pushAddTargets(for song: CarPlayModel.Row) {
        guard let model else { return }
        let targets = model.addTargets()
        let items = targets.map { target -> CPListItem in
            let item = CPListItem(text: target.title, detailText: target.subtitle)
            item.handler = { [weak self] _, completion in
                let name = model.addSong(song.id, toTargetId: target.id)
                self?.interfaceController.popTemplate(animated: true, completion: nil)
                if let name { self?.toast("Added to \(name)") }
                completion()
            }
            return item
        }
        let section = CPListSection(items: items.isEmpty
            ? [CPListItem(text: "No pockets or playlists yet", detailText: nil)] : items)
        let template = CPListTemplate(title: "Add “\(song.title)”", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    /// Build a CPListItem for a row, wiring its tap handler and kicking off async artwork.
    private func listItem(_ row: CarPlayModel.Row, showsDisclosure: Bool,
                          onTap: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: row.subtitle)
        if showsDisclosure { item.accessoryType = .disclosureIndicator }
        item.handler = { _, completion in onTap(); completion() }
        loadArtwork(albumId: row.artworkAlbumId, into: item)
        return item
    }

    /// Resolve the first working cover-art candidate → UIImage and set it on the item.
    private func loadArtwork(albumId: String?, into item: CPListItem) {
        guard let albumId else { return }
        if let cached = artCache[albumId] { item.setImage(cached); return }
        guard let model else { return }
        let urls = model.artCandidates(albumId: albumId)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            for url in urls {
                if let (data, resp) = try? await URLSession.shared.data(from: url),
                   (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                   let image = UIImage(data: data) {
                    self?.artCache[albumId] = image
                    item.setImage(image)
                    return
                }
            }
        }
    }

    private func showNowPlaying() {
        // Avoid stacking duplicate Now Playing templates.
        if interfaceController.topTemplate is CPNowPlayingTemplate { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // MARK: - Up Next (queue view + edit)

    /// Push the upcoming-queue list (Now Playing "Up Next" button → here).
    func showUpNext() {
        let template = CPListTemplate(title: "Up Next", sections: [upNextSection()])
        upNextTemplate = template
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func upNextSection() -> CPListSection {
        guard let model else { return CPListSection(items: []) }
        let items = model.upNext().map { item -> CPListItem in
            let li = CPListItem(text: item.title, detailText: item.artist)
            li.handler = { [weak self] _, completion in self?.presentUpNextActions(item); completion() }
            loadArtwork(albumId: item.albumId, into: li)
            return li
        }
        return CPListSection(items: items.isEmpty
            ? [CPListItem(text: "Nothing up next", detailText: nil)] : items)
    }

    /// A tap on an Up Next row → Remove / Play next / Move to end (CarPlay has no swipe-to-delete).
    private func presentUpNextActions(_ item: CarPlayModel.UpNextItem) {
        guard let model else { return }
        let remove = CPAlertAction(title: "Remove from queue", style: .destructive) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.removeFromQueue(uid: item.uid)
            self?.refreshUpNext()
        }
        let playNext = CPAlertAction(title: "Play next", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.playNext(uid: item.uid)
            self?.refreshUpNext()
        }
        let toEnd = CPAlertAction(title: "Move to end", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            model.moveToEnd(uid: item.uid)
            self?.refreshUpNext()
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let sheet = CPActionSheetTemplate(title: item.title, message: item.artist,
                                          actions: [remove, playNext, toEnd, cancel])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// Rebuild the Up Next list in place after an edit.
    private func refreshUpNext() { upNextTemplate?.updateSections([upNextSection()]) }

    private func toast(_ message: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPActionSheetTemplate(title: message, message: nil, actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}

/// Observes the shared Now Playing template — routes the "Up Next" button tap to the controller so
/// the driver can see + edit the upcoming queue.
final class CarPlayNowPlayingObserver: NSObject, CPNowPlayingTemplateObserver {
    private weak var controller: CarPlayController?
    init(controller: CarPlayController) { self.controller = controller }
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { controller?.showUpNext() }
    }
}

#endif
