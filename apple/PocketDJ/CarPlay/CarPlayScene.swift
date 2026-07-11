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
                            playAll: { await model.playPlaylist(id: row.id) })
        }
        let pockets = listTemplate(title: "Pockets", tabImageName: "square.stack.fill",
                                   rows: model.pockets()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inPocket: row.id),
                            playAll: { await model.playPocket(id: row.id) })
        }
        let albums = listTemplate(title: "Albums", tabImageName: "opticaldisc",
                                  rows: model.albums()) { [weak self] row in
            self?.pushSongs(title: row.title, rows: model.songs(inAlbum: row.id),
                            playAll: { await model.playAlbum(id: row.id) })
        }
        let search = searchTabTemplate()

        let tabBar = CPTabBarTemplate(templates: [playlists, pockets, albums, search])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
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

    /// Drill into a collection's songs, with a "Play all" row on top; a song opens the action sheet.
    private func pushSongs(title: String, rows: [CarPlayModel.Row], playAll: @escaping () async -> Void) {
        var sections: [CPListSection] = []
        if !rows.isEmpty {
            let playAllItem = CPListItem(text: "▶ Play all", detailText: nil)
            playAllItem.handler = { [weak self] _, completion in
                Task { await playAll(); self?.showNowPlaying(); completion() }
            }
            sections.append(CPListSection(items: [playAllItem]))
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

    // MARK: - Search

    private func searchTabTemplate() -> CPListTemplate {
        let searchRow = CPListItem(text: "Search library", detailText: "By title or artist")
        searchRow.handler = { [weak self] _, completion in
            self?.pushSearch(); completion()
        }
        let template = CPListTemplate(title: "Search", sections: [CPListSection(items: [searchRow])])
        template.tabImage = UIImage(systemName: "magnifyingglass")
        template.tabTitle = "Search"
        return template
    }

    private lazy var searchDelegate = CarPlaySearchDelegate(controller: self)

    private func pushSearch() {
        let template = CPSearchTemplate()
        template.delegate = searchDelegate
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// Search results as list items (used by the search delegate).
    func searchItems(for query: String) -> [CPListItem] {
        guard let model else { return [] }
        return model.search(query).map { row in
            let item = listItem(row, showsDisclosure: false) { [weak self] in
                Task { await model.playSong(id: row.id); self?.showNowPlaying() }
            }
            return item
        }
    }

    // MARK: - Helpers

    /// Build a CPListItem for a row, wiring its tap handler and kicking off async artwork.
    private func listItem(_ row: CarPlayModel.Row, showsDisclosure: Bool,
                          onTap: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: row.subtitle)
        if showsDisclosure { item.accessoryType = .disclosureIndicator }
        item.handler = { _, completion in onTap(); completion() }
        loadArtwork(for: row, into: item)
        return item
    }

    /// Resolve the first working cover-art candidate → UIImage and set it on the item.
    private func loadArtwork(for row: CarPlayModel.Row, into item: CPListItem) {
        guard let albumId = row.artworkAlbumId else { return }
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

    private func toast(_ message: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPActionSheetTemplate(title: message, message: nil, actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}

/// CPSearchTemplate delegate — returns title/artist search results and plays the picked song.
final class CarPlaySearchDelegate: NSObject, CPSearchTemplateDelegate {
    private weak var controller: CarPlayController?
    init(controller: CarPlayController) { self.controller = controller }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        completionHandler(controller?.searchItems(for: searchText) ?? [])
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        // The item carries its own tap handler (plays the song); fire it.
        item.handler?(item, completionHandler) ?? completionHandler()
    }
}
#endif
