package com.levi.pocketdj

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.screens.PlaceholderScreen
import com.levi.pocketdj.screens.browse.AlbumDetailScreen
import com.levi.pocketdj.screens.browse.ArtistDetailScreen
import com.levi.pocketdj.screens.browse.BrowseScreen
import com.levi.pocketdj.screens.browse.MiniPlayerBar
import com.levi.pocketdj.screens.browse.SongDetailSheet
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.screens.history.HistoryScreen
import com.levi.pocketdj.screens.jukebox.JukeboxScreen
import com.levi.pocketdj.screens.playlists.PlaylistDetailScreen
import com.levi.pocketdj.screens.playlists.PlaylistsScreen
import com.levi.pocketdj.screens.playlists.PocketDetailScreen
import com.levi.pocketdj.screens.playlists.SetlistDetailScreen
import com.levi.pocketdj.screens.playlists.SourcePlaylistDetailScreen
import com.levi.pocketdj.screens.settings.SettingsScreen
import com.levi.pocketdj.screens.settings.StorageScreen
import com.levi.pocketdj.ui.theme.PocketDjTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Eagerly build the graph + history store so every play is recorded
        // (the store subscribes to PlayEventBus) even before any screen opens.
        // The store constructor reads + decodes the whole log from disk (multi-MB
        // at the 20k cap), so construction happens OFF-MAIN per its own contract.
        val graph = AppGraph.get(this)
        val appContext = applicationContext
        graph.appScope.launch { PlayHistoryStore.get(appContext) }
        setContent {
            PocketDjTheme {
                PocketDjApp()
            }
        }
    }
}

const val SETTINGS_ROUTE = "settings"
const val SETTINGS_STORAGE_ROUTE = "settings/storage"
const val ALBUM_ROUTE = "album/{albumId}"
const val ARTIST_ROUTE = "artist/{artistName}"
const val PLAYLIST_ROUTE = "playlist/{playlistId}"
const val POCKET_ROUTE = "pocket/{pocketId}"
const val SETLIST_ROUTE = "setlist/{setlistId}?autoplay={autoplay}"
const val SOURCE_PLAYLIST_ROUTE = "sourcePlaylist/{playlistId}/{sourceName}"

fun albumRoute(albumId: String): String = "album/${android.net.Uri.encode(albumId)}"

fun artistRoute(name: String): String = "artist/${android.net.Uri.encode(name)}"

fun playlistRoute(playlistId: String): String = "playlist/${android.net.Uri.encode(playlistId)}"

fun pocketRoute(pocketId: String): String = "pocket/${android.net.Uri.encode(pocketId)}"

fun setlistRoute(setlistId: String, autoplay: Boolean): String =
    "setlist/${android.net.Uri.encode(setlistId)}?autoplay=$autoplay"

fun sourcePlaylistRoute(playlistId: String, sourceName: String): String =
    "sourcePlaylist/${android.net.Uri.encode(playlistId)}/${android.net.Uri.encode(sourceName)}"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PocketDjApp() {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val currentRoute = currentDestination?.route

    // App-level snackbar: surfaces async playback errors (a failed rip-on-demand
    // finishes long after the tab that started it may be gone).
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val appSnackbar = remember { SnackbarHostState() }
    val playbackError by graph.playbackController.lastError.collectAsState()
    LaunchedEffect(playbackError) {
        playbackError?.let { message ->
            appSnackbar.showSnackbar(message)
            graph.playbackController.clearLastError()
        }
    }

    val currentTab = PocketDjDestination.bottomNav.firstOrNull { it.route == currentRoute }
    // Any non-tab route is a pushed detail screen: back arrow + its own title.
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
        else -> currentTab?.label ?: "PocketDJ"
    }

    Scaffold(
        snackbarHost = { SnackbarHost(hostState = appSnackbar) },
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (onDetail) {
                        IconButton(onClick = { navController.popBackStack() }) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                            )
                        }
                    }
                },
                actions = {
                    // Settings ships inside Browse (product decision): show the gear only there.
                    if (currentTab == PocketDjDestination.Browse) {
                        IconButton(onClick = { navController.navigate(SETTINGS_ROUTE) }) {
                            Icon(Icons.Filled.Settings, contentDescription = "Settings")
                        }
                    }
                },
            )
        },
        bottomBar = {
            Column {
                // Renders nothing while idle; docks above the nav bar when playing.
                MiniPlayerBar()
                NavigationBar {
                    PocketDjDestination.bottomNav.forEach { dest ->
                        val selected = currentDestination?.hierarchy?.any { it.route == dest.route } == true
                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                navController.navigate(dest.route) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(dest.icon, contentDescription = dest.label) },
                            // Single line, slightly smaller so the longest labels
                            // ("Collections", "Producer") never wrap across two lines.
                            label = { Text(dest.label, maxLines = 1, softWrap = false, fontSize = 10.sp) },
                        )
                    }
                }
            }
        },
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = PocketDjDestination.Browse.route,
            modifier = Modifier.padding(innerPadding),
        ) {
            composable(PocketDjDestination.Browse.route) {
                BrowseScreen(
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                    onOpenArtist = { name -> navController.navigate(artistRoute(name)) },
                )
            }
            composable(PocketDjDestination.History.route) {
                // Row tap → song detail (specs/history.md §6); the sheet's album
                // row navigates on to album detail like Browse.
                var detailSongId by remember { mutableStateOf<String?>(null) }
                HistoryScreen(onSongClick = { detailSongId = it })
                detailSongId?.let { songId ->
                    SongDetailSheet(
                        songId = songId,
                        onDismiss = { detailSongId = null },
                        snackbar = appSnackbar,
                        onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                    )
                }
            }
            composable(PocketDjDestination.Jukebox.route) {
                JukeboxScreen()
            }
            composable(PocketDjDestination.Playlists.route) {
                PlaylistsScreen(
                    onOpenPlaylist = { id -> navController.navigate(playlistRoute(id)) },
                    onOpenPocket = { id -> navController.navigate(pocketRoute(id)) },
                    onOpenSourcePlaylist = { id, sourceName ->
                        navController.navigate(sourcePlaylistRoute(id, sourceName))
                    },
                )
            }
            listOf(
                PocketDjDestination.Mix,
                PocketDjDestination.Producer,
            ).forEach { dest ->
                composable(dest.route) {
                    PlaceholderScreen(title = dest.label, phase = dest.phase)
                }
            }
            composable(
                route = PLAYLIST_ROUTE,
                arguments = listOf(navArgument("playlistId") { type = NavType.StringType }),
            ) { entry ->
                PlaylistDetailScreen(
                    playlistId = entry.arguments?.getString("playlistId").orEmpty(),
                    onOpenSetlist = { id, autoplay -> navController.navigate(setlistRoute(id, autoplay)) },
                    onOpenPocket = { id -> navController.navigate(pocketRoute(id)) },
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                    onDeleted = { navController.popBackStack() },
                )
            }
            composable(
                route = POCKET_ROUTE,
                arguments = listOf(navArgument("pocketId") { type = NavType.StringType }),
            ) { entry ->
                PocketDetailScreen(
                    pocketId = entry.arguments?.getString("pocketId").orEmpty(),
                    onOpenPocket = { id -> navController.navigate(pocketRoute(id)) },
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                    onOpenSetlist = { id, autoplay -> navController.navigate(setlistRoute(id, autoplay)) },
                    onDeleted = { navController.popBackStack() },
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
                    onDeleted = { navController.popBackStack() },
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
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
                    onOpenSetlist = { id, autoplay -> navController.navigate(setlistRoute(id, autoplay)) },
                    onOpenPlaylist = { id -> navController.navigate(playlistRoute(id)) },
                    onOpenPocket = { id -> navController.navigate(pocketRoute(id)) },
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                )
            }
            composable(
                route = ALBUM_ROUTE,
                arguments = listOf(navArgument("albumId") { type = NavType.StringType }),
            ) { entry ->
                val albumId = entry.arguments?.getString("albumId").orEmpty()
                AlbumDetailScreen(albumId = albumId)
            }
            composable(
                route = ARTIST_ROUTE,
                arguments = listOf(navArgument("artistName") { type = NavType.StringType }),
            ) { entry ->
                ArtistDetailScreen(
                    artistName = entry.arguments?.getString("artistName").orEmpty(),
                    onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) },
                    onOpenSetlist = { id, autoplay -> navController.navigate(setlistRoute(id, autoplay)) },
                )
            }
            composable(SETTINGS_ROUTE) {
                SettingsScreen(
                    onOpenStorage = { navController.navigate(SETTINGS_STORAGE_ROUTE) },
                )
            }
            composable(SETTINGS_STORAGE_ROUTE) {
                StorageScreen()
            }
        }
    }
}
