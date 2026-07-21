package com.levi.pocketdj

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.screens.PlaceholderScreen
import com.levi.pocketdj.screens.SettingsScreen
import com.levi.pocketdj.ui.theme.PocketDjTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            PocketDjTheme {
                PocketDjApp()
            }
        }
    }
}

const val SETTINGS_ROUTE = "settings"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PocketDjApp() {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val currentRoute = currentDestination?.route

    val currentTab = PocketDjDestination.bottomNav.firstOrNull { it.route == currentRoute }
    val onSettings = currentRoute == SETTINGS_ROUTE
    val title = when {
        onSettings -> "Settings"
        currentTab != null -> currentTab.label
        else -> "PocketDJ"
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (onSettings) {
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
        },
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = PocketDjDestination.Browse.route,
            modifier = Modifier.padding(innerPadding),
        ) {
            PocketDjDestination.bottomNav.forEach { dest ->
                composable(dest.route) {
                    PlaceholderScreen(title = dest.label, phase = dest.phase)
                }
            }
            composable(SETTINGS_ROUTE) {
                SettingsScreen()
            }
        }
    }
}
