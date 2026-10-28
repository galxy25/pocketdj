package com.levi.pocketdj.shell

import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.filterNotNull
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.onboarding.OnboardingScreen
import com.levi.pocketdj.onboarding.OnboardingStore
import com.levi.pocketdj.screens.PlaceholderScreen
import com.levi.pocketdj.screens.browse.AlbumDetailScreen
import com.levi.pocketdj.screens.browse.ArtistDetailScreen
import com.levi.pocketdj.screens.browse.BrowseScreen
import com.levi.pocketdj.screens.browse.MiniPlayerBar
import com.levi.pocketdj.screens.nowplaying.NOW_PLAYING_ROUTE
import com.levi.pocketdj.screens.browse.SongDetailSheet
import com.levi.pocketdj.screens.history.HistoryScreen
import com.levi.pocketdj.screens.jukebox.JukeboxScreen
import com.levi.pocketdj.screens.playlists.PlaylistDetailScreen
import com.levi.pocketdj.screens.playlists.PlaylistsScreen
import com.levi.pocketdj.screens.playlists.PocketDetailScreen
import com.levi.pocketdj.screens.playlists.SetlistDetailScreen
import com.levi.pocketdj.screens.playlists.SourcePlaylistDetailScreen
import com.levi.pocketdj.screens.settings.SettingsScreen
import com.levi.pocketdj.screens.settings.StorageScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

const val SETTINGS_ROUTE = "settings"
const val SETTINGS_STORAGE_ROUTE = "settings/storage"
const val ALBUM_ROUTE = "album/{albumId}"
const val ARTIST_ROUTE = "artist/{artistName}"
const val PLAYLIST_ROUTE = "playlist/{playlistId}"
const val POCKET_ROUTE = "pocket/{pocketId}"
const val SETLIST_ROUTE = "setlist/{setlistId}?autoplay={autoplay}"
const val JUKEBOX_JOIN_ROUTE = "jukebox/join/{jukeboxId}"
const val SOURCE_PLAYLIST_ROUTE = "sourcePlaylist/{playlistId}/{sourceName}"

fun albumRoute(albumId: String): String = "album/${Uri.encode(albumId)}"
fun artistRoute(name: String): String = "artist/${Uri.encode(name)}"
fun playlistRoute(playlistId: String): String = "playlist/${Uri.encode(playlistId)}"
fun pocketRoute(pocketId: String): String = "pocket/${Uri.encode(pocketId)}"
fun setlistRoute(setlistId: String, autoplay: Boolean): String =
    "setlist/${Uri.encode(setlistId)}?autoplay=$autoplay"
fun jukeboxJoinRoute(jukeboxId: String): String = "jukebox/join/${Uri.encode(jukeboxId)}"
fun sourcePlaylistRoute(playlistId: String, sourceName: String): String =
    "sourcePlaylist/${Uri.encode(playlistId)}/${Uri.encode(sourceName)}"

/** The nav-graph route string for a pushed (detail) [ShellRoute]; null for non-pushes. */
fun pushRouteFor(route: ShellRoute): String? = when (route) {
    is ShellRoute.Album -> albumRoute(route.id)
    is ShellRoute.Artist -> artistRoute(route.name)
    is ShellRoute.Playlist -> playlistRoute(route.id)
    is ShellRoute.Pocket -> pocketRoute(route.id)
    is ShellRoute.Setlist -> setlistRoute(route.id, route.autoplay)
    is ShellRoute.SourcePlaylist -> sourcePlaylistRoute(route.id, route.sourceName)
    is ShellRoute.JukeboxJoin -> jukeboxJoinRoute(route.id)
    is ShellRoute.BrowseSearch, is ShellRoute.Tab -> null
}

/** Compact windows get the bottom bar, medium+ (>= 600 dp) a rail. Pure for tests. */
fun navLayoutFor(widthDp: Int): ShellNavLayout =
    if (widthDp >= RAIL_MIN_WIDTH_DP) ShellNavLayout.Rail else ShellNavLayout.Bar

enum class ShellNavLayout { Bar, Rail }

const val RAIL_MIN_WIDTH_DP = 600

/** The long tab-switch settle iOS uses before a staged push (sheet dismissal ≈ 400 ms). */
const val STAGED_PUSH_DELAY_MS = 450L

/** [RouteLookup] over the live graph. Catalog-dependent checks wait (bounded) for the catalog. */
private class GraphRouteLookup(private val graph: AppGraph) : RouteLookup {
    private val catalog get() = graph.catalogRepository.state.value.catalog

    override fun albumExists(id: String) = catalog?.albumsById?.containsKey(id) == true
    override fun playlistExists(id: String) = graph.collections.playlist(id) != null
    override fun pocketExists(id: String) = graph.collections.pocket(id) != null
    override fun setlistExists(id: String) = graph.collections.setlist(id) != null
    override fun sourcePlaylistExists(id: String) =
        catalog?.playlists?.any { it.playlist.id == id } == true

    override fun jukeboxSessionJoined(id: String) =
        com.levi.pocketdj.data.jukebox.JukeboxGraph.joinedSessions(graph.appContext).contains(id)
}

private suspend fun resolveOffMain(graph: AppGraph, route: ShellRoute): RouteResolution =
    withContext(Dispatchers.Default) {
        val needsCatalog = route is ShellRoute.Album || route is ShellRoute.SourcePlaylist
        if (needsCatalog && graph.catalogRepository.state.value.catalog == null) {
            graph.catalogRepository.loadIfNeeded()
            withTimeoutOrNull(5_000) { graph.catalogRepository.state.first { it.catalog != null } }
        }
        ShellRouteResolver.resolve(route, GraphRouteLookup(graph))
    }

/**
 * Long-lived NavRequestBus consumer. Each taken route is handled in its own child
 * coroutine so a slow resolve / staged-push delay / snackbar never blocks or is
 * cancelled by the signal clearing. Extracted from the composable so it is testable.
 */
suspend fun consumeNavRequests(
    resolve: suspend (ShellRoute) -> RouteResolution,
    switchTab: (PocketDjDestination) -> Unit,
    push: (String) -> Unit,
    showMessage: suspend (String) -> Unit,
    stagedDelayMs: Long = STAGED_PUSH_DELAY_MS,
    pushTarget: (ShellRoute) -> String? = ::pushRouteFor,
) = coroutineScope {
    NavRequestBus.signal.filterNotNull().collect {
        val route = NavRequestBus.take() ?: return@collect // another consumer won
        launch {
            when (val resolved = resolve(route)) {
                is RouteMessage -> {
                    // The section still lands (iOS sets `section` before checking the target).
                    route.homeTab()?.let(switchTab)
                    showMessage("${ShellRouteResolver.ALERT_TITLE} — ${resolved.text}")
                }
                is NavCommand -> {
                    resolved.pendingBrowseQuery?.let { NavRequestBus.setPendingBrowseQuery(it) }
                    switchTab(resolved.tab)
                    resolved.push?.let(pushTarget)?.let { target ->
                        delay(stagedDelayMs)
                        push(target)
                    }
                }
            }
        }
    }
}

private fun NavController.switchTab(dest: PocketDjDestination, fresh: Boolean) {
    navigate(dest.route) {
        popUpTo(graph.findStartDestination().id) { saveState = !fresh }
        launchSingleTop = true
        restoreState = !fresh
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PocketDjApp() {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    // Restore the last-visited section before the NavHost exists (its start destination is fixed).
    // rememberSaveable (token) so a re-created activity reuses the ORIGINAL start: the
    // restored NavController back stack is rooted there, and popUpTo(findStartDestination)
    // must keep pointing at that root.
    var startToken by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(graph) {
        if (startToken == null) startToken = graph.lastSection.restore().token
    }
    val resolvedStart = startToken?.let { PocketDjDestination.fromToken(it) }

    // Zero-to-hero gate (SURF-3): while the flow is incomplete the app proper is NOT composed,
    // so no screen starts the catalog load / rips manifest / jukebox bootstrap. The debug
    // intent extra forces the flow for emulator verification.
    val onboarding = graph.onboarding
    androidx.compose.runtime.saveable.rememberSaveable(onboarding) {
        val activity = context as? android.app.Activity
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable && activity?.intent?.getBooleanExtra(OnboardingStore.SHOW_INTENT_EXTRA, false) == true) {
            onboarding.forceShow()
        }
        true
    }
    val onboardingState by onboarding.state.collectAsState()
    when {
        !onboardingState.loaded -> Box(Modifier.fillMaxSize())
        !onboardingState.complete -> OnboardingScreen(graph, onboarding)
        resolvedStart == null -> Box(Modifier.fillMaxSize())
        else -> ShellContent(graph, resolvedStart)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShellContent(graph: AppGraph, startTab: PocketDjDestination) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val currentRoute = currentDestination?.route
    val appSnackbar = remember { SnackbarHostState() }

    // App-level snackbar: surfaces async playback errors (a failed rip-on-demand
    // finishes long after the tab that started it may be gone).
    val playbackError by graph.playbackController.lastError.collectAsState()
    LaunchedEffect(playbackError) {
        playbackError?.let { message ->
            appSnackbar.showSnackbar(message)
            graph.playbackController.clearLastError()
        }
    }

    // Persist the last-visited tab (token = iOS Section.rawValue).
    val currentTab = PocketDjDestination.bottomNav.firstOrNull { it.route == currentRoute }
    LaunchedEffect(currentTab) { currentTab?.let { graph.lastSection.save(it) } }

    // NavRequestBus consumer: atomic take (clear first), tab switches NOW on a fresh stack,
    // the push is staged after the settle delay — RootView.consumeIntentRoute's discipline.
    // Keyed on Unit: take() clears the signal, so keying on it would cancel the very
    // coroutine that is mid-resolve / mid-delay / showing the snackbar.
    LaunchedEffect(Unit) {
        consumeNavRequests(
            resolve = { route -> resolveOffMain(graph, route) },
            switchTab = { navController.switchTab(it, fresh = true) },
            push = { navController.navigate(it) },
            showMessage = { appSnackbar.showSnackbar(it) },
        )
    }
    // Direct postMessage callers (deep links) must never be a silent no-op.
    LaunchedEffect(Unit) {
        NavRequestBus.routeMessage.filterNotNull().collect { text ->
            NavRequestBus.clearMessage()
            launch { appSnackbar.showSnackbar("${ShellRouteResolver.ALERT_TITLE} — $text") }
        }
    }

    val onDetail = currentTab == null && currentRoute != null
    val title = when (currentRoute) {
        SETTINGS_ROUTE -> "Settings"
        SETTINGS_STORAGE_ROUTE -> "Storage"
        ALBUM_ROUTE -> "Album"
        ARTIST_ROUTE -> backStackEntry?.arguments?.getString("artistName") ?: "Artist"
        PLAYLIST_ROUTE -> "Playlist"
        POCKET_ROUTE -> "Pocket"
        SETLIST_ROUTE ->
            if (backStackEntry?.arguments?.getString("setlistId") == NOW_PLAYING_SETLIST_ID) {
                "Now Playing"
            } else {
                "Set list"
            }
        SOURCE_PLAYLIST_ROUTE -> "Source playlist"
        JUKEBOX_JOIN_ROUTE -> "Jukebox"
        NOW_PLAYING_ROUTE -> "Now Playing"
        else -> currentTab?.label ?: "PocketDJ"
    }

    val widthDp = LocalConfiguration.current.screenWidthDp
    val layout = navLayoutFor(widthDp)

    NavigationSuiteScaffold(
        layoutType = if (layout == ShellNavLayout.Rail) {
            NavigationSuiteType.NavigationRail
        } else {
            NavigationSuiteType.NavigationBar
        },
        navigationSuiteItems = {
            PocketDjDestination.bottomNav.forEach { dest ->
                val selected = currentDestination?.hierarchy?.any { it.route == dest.route } == true
                item(
                    selected = selected,
                    onClick = { navController.switchTab(dest, fresh = false) },
                    icon = { Icon(dest.icon, contentDescription = dest.label) },
                    // Compact bar: label on the SELECTED item only, so seven destinations
                    // fit a 360 dp phone without wrapping. The rail has room for all.
                    label = {
                        // 10.sp + Visible overflow: "Collections" (11 ch) is wider than a 7-up
                        // bar slot at 411 dp; neighbours' labels are hidden, so it may overhang.
                        Text(dest.label, maxLines = 1, softWrap = false, fontSize = 10.sp, overflow = TextOverflow.Visible)
                    },
                    alwaysShowLabel = layout == ShellNavLayout.Rail,
                )
            }
        },
    ) {
        Scaffold(
            contentWindowInsets = WindowInsets(0, 0, 0, 0),
            snackbarHost = { SnackbarHost(hostState = appSnackbar) },
            topBar = {
                TopAppBar(
                    title = { Text(title) },
                    navigationIcon = {
                        if (onDetail) {
                            IconButton(onClick = { navController.popBackStack() }) {
                                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                            }
                        }
                    },
                    actions = {
                        // Settings ships inside Browse (product decision): gear only there.
                        if (currentTab == PocketDjDestination.Browse) {
                            IconButton(onClick = { navController.navigate(SETTINGS_ROUTE) }) {
                                Icon(Icons.Filled.Settings, contentDescription = "Settings")
                            }
                        }
                    },
                )
            },
            // Renders nothing while idle; docks above the nav bar when playing.
            bottomBar = {
                MiniPlayerBar(
                    hidden = currentRoute == NOW_PLAYING_ROUTE,
                    onExpand = {
                        if (currentRoute != NOW_PLAYING_ROUTE) navController.navigate(NOW_PLAYING_ROUTE)
                    },
                )
            },
        ) { innerPadding ->
            ShellNavHost(navController, startTab, appSnackbar, graph, Modifier.padding(innerPadding))
            // COL-8: large-batch Apple Music write-back confirmation (renders nothing while idle).
            com.levi.pocketdj.screens.collections.WriteBackConfirmDialog(graph.collections)
        }
    }
}

/** The tab a route's section lands on (also when the target is missing). */
private fun ShellRoute.homeTab(): PocketDjDestination? = when (this) {
    is ShellRoute.Tab -> destination
    is ShellRoute.Album, is ShellRoute.Artist, is ShellRoute.BrowseSearch -> PocketDjDestination.Browse
    is ShellRoute.Playlist, is ShellRoute.Pocket, is ShellRoute.Setlist,
    is ShellRoute.SourcePlaylist -> PocketDjDestination.Playlists
    is ShellRoute.JukeboxJoin -> PocketDjDestination.Jukebox
}

@Composable
private fun ShellNavHost(
    navController: NavController,
    startTab: PocketDjDestination,
    appSnackbar: SnackbarHostState,
    graph: AppGraph,
    modifier: Modifier,
) {
    val nav = navController as androidx.navigation.NavHostController
    val actions = remember(nav) {
        object : ShellNavActions {
            override fun navigate(route: String) = nav.navigate(route)
            override fun pop() {
                nav.popBackStack()
            }
        }
    }
    val funnelScope = androidx.compose.runtime.rememberCoroutineScope()
    // ▶/🔀 funnels target the reserved Now Playing setlist: start the run, then open the deck.
    val openSetlist: (String, Boolean) -> Unit = { id, autoplay ->
        if (id == NOW_PLAYING_SETLIST_ID && autoplay) {
            funnelScope.launch {
                val sl = graph.collections.setlist(id)
                when (val outcome = sl?.let { graph.playbackController.playSetlist(it) }) {
                    is com.levi.pocketdj.playback.QueueOutcome.NothingPlayable ->
                        appSnackbar.showSnackbar("None of these tracks are playable on this device yet")
                    is com.levi.pocketdj.playback.QueueOutcome.Failed -> appSnackbar.showSnackbar(outcome.message)
                    else -> Unit
                }
            }
            if (nav.currentDestination?.route != NOW_PLAYING_ROUTE) nav.navigate(NOW_PLAYING_ROUTE)
        } else {
            nav.navigate(setlistRoute(id, autoplay))
        }
    }
    NavHost(
        navController = nav,
        startDestination = startTab.route,
        modifier = modifier,
    ) {
        composable(PocketDjDestination.Browse.route) {
            BrowseScreen(
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
                onOpenArtist = { name -> nav.navigate(artistRoute(name)) },
            )
        }
        composable(PocketDjDestination.History.route) {
            // Row tap → song detail (specs/history.md §6); the sheet's album row navigates
            // on to album detail like Browse.
            var detailSongId by remember { mutableStateOf<String?>(null) }
            HistoryScreen(onSongClick = { detailSongId = it })
            detailSongId?.let { songId ->
                SongDetailSheet(
                    songId = songId,
                    onDismiss = { detailSongId = null },
                    snackbar = appSnackbar,
                    onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
                )
            }
        }
        composable(PocketDjDestination.Jukebox.route) {
            JukeboxScreen(onOpenJoin = { id -> nav.navigate(jukeboxJoinRoute(id)) })
        }
        composable(
            route = JUKEBOX_JOIN_ROUTE,
            arguments = listOf(navArgument("jukeboxId") { type = NavType.StringType }),
        ) { entry ->
            com.levi.pocketdj.screens.jukebox.JukeboxJoinScreen(
                jukeboxId = entry.arguments?.getString("jukeboxId").orEmpty(),
                onClose = { nav.popBackStack() },
            )
        }
        composable(PocketDjDestination.Playlists.route) {
            PlaylistsScreen(
                onOpenPlaylist = { id -> nav.navigate(playlistRoute(id)) },
                onOpenPocket = { id -> nav.navigate(pocketRoute(id)) },
                onOpenSourcePlaylist = { id, sourceName ->
                    nav.navigate(sourcePlaylistRoute(id, sourceName))
                },
            )
        }
        composable(PocketDjDestination.Producer.route) {
            com.levi.pocketdj.screens.producer.ProducerRoute(graph)
        }
        composable(PocketDjDestination.Games.route) {
            com.levi.pocketdj.screens.games.GamesRoute(graph)
        }
        composable(PocketDjDestination.Mix.route) {
            com.levi.pocketdj.screens.mix.MixRoute(
                graph,
                onOpenSessions = { nav.navigate(com.levi.pocketdj.screens.mix.MixRoutes.SESSIONS) },
            )
        }
        composable(
            route = PLAYLIST_ROUTE,
            arguments = listOf(navArgument("playlistId") { type = NavType.StringType }),
        ) { entry ->
            PlaylistDetailScreen(
                playlistId = entry.arguments?.getString("playlistId").orEmpty(),
                onOpenSetlist = openSetlist,
                onOpenPocket = { id -> nav.navigate(pocketRoute(id)) },
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
                onDeleted = { nav.popBackStack() },
            )
        }
        composable(
            route = POCKET_ROUTE,
            arguments = listOf(navArgument("pocketId") { type = NavType.StringType }),
        ) { entry ->
            PocketDetailScreen(
                pocketId = entry.arguments?.getString("pocketId").orEmpty(),
                onOpenPocket = { id -> nav.navigate(pocketRoute(id)) },
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
                onOpenSetlist = openSetlist,
                onDeleted = { nav.popBackStack() },
            )
        }
        composable(
            route = SETLIST_ROUTE,
            arguments = listOf(
                navArgument("setlistId") { type = NavType.StringType },
                navArgument("autoplay") {
                    type = NavType.BoolType
                    defaultValue = false
                },
            ),
        ) { entry ->
            SetlistDetailScreen(
                setlistId = entry.arguments?.getString("setlistId").orEmpty(),
                autoplay = entry.arguments?.getBoolean("autoplay") == true,
                onDeleted = { nav.popBackStack() },
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
            )
        }
        composable(
            route = SOURCE_PLAYLIST_ROUTE,
            arguments = listOf(
                navArgument("playlistId") { type = NavType.StringType },
                navArgument("sourceName") { type = NavType.StringType },
            ),
        ) { entry ->
            SourcePlaylistDetailScreen(
                playlistId = entry.arguments?.getString("playlistId").orEmpty(),
                sourceName = entry.arguments?.getString("sourceName").orEmpty(),
                onOpenSetlist = openSetlist,
                onOpenPlaylist = { id -> nav.navigate(playlistRoute(id)) },
                onOpenPocket = { id -> nav.navigate(pocketRoute(id)) },
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
            )
        }
        composable(
            route = ALBUM_ROUTE,
            arguments = listOf(navArgument("albumId") { type = NavType.StringType }),
        ) { entry ->
            AlbumDetailScreen(
                albumId = entry.arguments?.getString("albumId").orEmpty(),
                onOpenSetlist = openSetlist,
            )
        }
        composable(
            route = ARTIST_ROUTE,
            arguments = listOf(navArgument("artistName") { type = NavType.StringType }),
        ) { entry ->
            ArtistDetailScreen(
                artistName = entry.arguments?.getString("artistName").orEmpty(),
                onOpenAlbum = { albumId -> nav.navigate(albumRoute(albumId)) },
                onOpenSetlist = openSetlist,
            )
        }
        composable(SETTINGS_ROUTE) {
            SettingsScreen(onOpenStorage = { nav.navigate(SETTINGS_STORAGE_ROUTE) })
        }
        composable(SETTINGS_STORAGE_ROUTE) {
            StorageScreen()
        }
        // Area-contributed pushed routes (decision D3): no edit here per package.
        graph.features.navEntries.forEach { entry -> entry.register(this, actions) }
    }
}
