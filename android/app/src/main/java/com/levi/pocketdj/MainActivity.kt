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
import com.levi.pocketdj.screens.browse.BrowseScreen
import com.levi.pocketdj.screens.browse.MiniPlayerBar
import com.levi.pocketdj.screens.browse.SongDetailSheet
import com.levi.pocketdj.screens.history.HistoryScreen
import com.levi.pocketdj.screens.jukebox.JukeboxScreen
import com.levi.pocketdj.screens.settings.SettingsScreen
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
const val ALBUM_ROUTE = "album/{albumId}"

fun albumRoute(albumId: String): String = "album/${android.net.Uri.encode(albumId)}"

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
    val onSettings = currentRoute == SETTINGS_ROUTE
    val onAlbum = currentRoute == ALBUM_ROUTE
    val title = when {
        onSettings -> "Settings"
        onAlbum -> "Album"
        currentTab != null -> currentTab.label
        else -> "PocketDJ"
    }

    Scaffold(
        snackbarHost = { SnackbarHost(hostState = appSnackbar) },
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (onSettings || onAlbum) {
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
                            label = { Text(dest.label) },
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
                BrowseScreen(onOpenAlbum = { albumId -> navController.navigate(albumRoute(albumId)) })
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
            listOf(
                PocketDjDestination.Playlists,
                PocketDjDestination.Mix,
                PocketDjDestination.Producer,
            ).forEach { dest ->
                composable(dest.route) {
                    PlaceholderScreen(title = dest.label, phase = dest.phase)
                }
            }
            composable(
                route = ALBUM_ROUTE,
                arguments = listOf(navArgument("albumId") { type = NavType.StringType }),
            ) { entry ->
                val albumId = entry.arguments?.getString("albumId").orEmpty()
                AlbumDetailScreen(albumId = albumId)
            }
            composable(SETTINGS_ROUTE) {
                SettingsScreen()
            }
        }
    }
}
