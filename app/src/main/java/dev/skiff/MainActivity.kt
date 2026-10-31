package dev.skiff

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ButtonGroupDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.skiff.atv.Atv
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    /** The last IMDb page shared to us, read by the screen (null = nothing new). */
    private var shared by mutableStateOf<Title.Shared?>(null)
    /** A screen to open at once: "remote" (the Quick Settings tile), "library", "settings", "activity". */
    private var openScreen by mutableStateOf<String?>(null)

    companion object {
        /** `adb shell am start -n dev.skiff.debug/dev.skiff.MainActivity --es screen remote`, for screenshots too. */
        const val EXTRA_SCREEN = "screen"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Demo.init(this, if (intent.hasExtra("demo")) intent.getBooleanExtra("demo", false) else null)
        Telemetry.init(this)
        if (intent.getBooleanExtra("test_crash", false)) Telemetry.testCrash(this)
        Rules.init(this)
        shared = sharedTitle(intent)
        openScreen = intent.getStringExtra(EXTRA_SCREEN)
        setContent {
            AppTheme {
                RemoteScreen(shared, onSharedUsed = { shared = null }, openScreen = openScreen, onOpenScreenUsed = { openScreen = null })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedTitle(intent)?.let { shared = it }
        intent.getStringExtra(EXTRA_SCREEN)?.let { openScreen = it }
    }

    /** The volume buttons go to the TV while the remote is connected (HardwareKeys). */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean =
        HardwareKeys.dispatch(event) || super.dispatchKeyEvent(event)

    /** Chrome shares the page's URL as the text and its title as the subject; the IMDb app, both in the text. */
    private fun sharedTitle(intent: Intent?): Title.Shared? =
        if (intent?.action == Intent.ACTION_SEND) {
            Title.fromShared(intent.getStringExtra(Intent.EXTRA_TEXT), intent.getStringExtra(Intent.EXTRA_SUBJECT))
        } else null
}

/** Material You colors (from the wallpaper, Android 12+) with Material 3 Expressive motion and shapes. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialExpressiveTheme(colorScheme = colors, motionScheme = MotionScheme.expressive(), content = content)
}

private const val PREFS = "remote"

/** Search results shown at a time; the next ones as the list is scrolled to its end. */
private const val SEARCH_PAGE = 8

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun RemoteScreen(shared: Title.Shared?, onSharedUsed: () -> Unit, openScreen: String?, onOpenScreenUsed: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    val scope = rememberCoroutineScope()
    // History and Saved for later.
    val library = remember { Library.get(context) }
    val entries by library.entries.collectAsState()
    var showLibrary by remember { mutableStateOf(false) }
    var showRemote by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var openActivity by remember { mutableStateOf(false) }     // Settings opened on Activity
    var openUpdate by remember { mutableStateOf(false) }       // Settings opened on the update sheet
    // Back after allowing Skiff to install apps (Android restarted it): the update, where you left it.
    LaunchedEffect(Unit) {
        if (Updates.resumeAfterAllow(context)) {
            openUpdate = true
            showSettings = true
        }
    }
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val keyboard = LocalSoftwareKeyboardController.current

    // The TV
    var host by remember { mutableStateOf(prefs.getString("host", "").orEmpty()) }
    // The TV picked from the list, by name: if the router gives it a new address, we follow it.
    var tvName by remember { mutableStateOf(prefs.getString("tvName", "").orEmpty()) }
    var tvs by remember { mutableStateOf(emptyList<TvFinder.Tv>()) }
    var searching by remember { mutableStateOf(true) }
    var searchRun by remember { mutableIntStateOf(0) }
    var manual by remember { mutableStateOf(false) }
    // The Nuvio apps on that TV (Play Store and GitHub builds, forks), and the one to open titles in.
    var apps by remember { mutableStateOf(emptyList<TvLink.NuvioApp>()) }
    var appsLoading by remember { mutableStateOf(false) }
    var appsError by remember { mutableStateOf<String?>(null) }
    var appsRun by remember { mutableIntStateOf(0) }
    var appComponent by remember { mutableStateOf(prefs.getString("app", null)) }
    // Over pairing there's no list of the TV's apps: titles open in the one you pick, Nuvio or Stremio.
    var pairedStremio by remember { mutableStateOf(prefs.getString("titleApp", "nuvio") == "stremio") }
    LaunchedEffect(pairedStremio) { prefs.edit().putString("titleApp", if (pairedStremio) "stremio" else "nuvio").apply() }
    val finder = remember {
        TvFinder(context) { found ->
            tvs = found
            // A paired TV at a new address (the router moved it) keeps its pairing, found by its name.
            for (tv in found) Atv.adopt(context, tv.host, tv.name)
            // Usable: USB debugging on, or paired (the Google TV remote protocol).
            fun usable(tv: TvFinder.Tv) = tv.ready || Atv.isPaired(context, tv.host)
            val same = found.firstOrNull { usable(it) && it.name == tvName }
            when {
                same != null -> host = same.host
                host.isBlank() -> (found.singleOrNull { usable(it) } ?: found.singleOrNull())?.let { host = it.host; tvName = it.name }
            }
        }
    }
    // Newer link rules from the repo, at most once a day; a newer Skiff, at most twice a day.
    LaunchedEffect(Unit) { Rules.refresh(context) }
    LaunchedEffect(Unit) { runCatching { Updates.check(context) } }
    DisposableEffect(Unit) {
        finder.start()
        onDispose { finder.stop() }
    }
    LaunchedEffect(searchRun) {
        searching = true
        delay(8_000)
        searching = false
    }

    // The title
    var series by remember { mutableStateOf(false) }
    var imdbId by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var meta by remember { mutableStateOf<Meta.Found?>(null) }
    var season by remember { mutableIntStateOf(1) }
    var episode by remember { mutableIntStateOf(1) }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    // The title was filled in for you (from the share or the lookup): a later lookup may replace it; yours, not.
    var autoName by remember { mutableStateOf(true) }
    var editName by remember { mutableStateOf(false) }
    var lookingUp by remember { mutableStateOf(false) }
    var notFound by remember { mutableStateOf(false) }
    // Shared a page: open it on the TV as soon as it's known to be a movie (a series waits for its episode).
    var openWhenKnown by remember { mutableStateOf(false) }
    var shareRun by remember { mutableIntStateOf(0) }     // the same page shared again looks it up again
    // Movie or series set by you (the toggle, or an entry you edited): the lookup doesn't change it back.
    var keepType by remember { mutableStateOf(false) }
    // Typed words that aren't a link or an IMDb id: a title search (Cinemeta), its results under the box.
    var hits by remember { mutableStateOf(emptyList<Meta.Hit>()) }
    var hitsFor by remember { mutableStateOf("") }      // the words those were found for: others typed since, not shown
    var shownHits by remember { mutableIntStateOf(SEARCH_PAGE) }     // a page at a time, more as the list is scrolled
    var findingTitles by remember { mutableStateOf(false) }
    var searchNow by remember { mutableIntStateOf(0) }      // the keyboard's Search: no waiting for more typing
    var searchedNow by remember { mutableIntStateOf(0) }
    // Or any other link (JioHotstar, YouTube…): opened on the TV by the app that opens such links.
    var link by remember { mutableStateOf<String?>(null) }
    var linkTitle by remember { mutableStateOf("") }       // what the share called it, until the page says
    // A link goes to history when shared, pasted or opened from it (or played): not while it's being typed.
    var recordLink by remember { mutableStateOf(false) }
    var page by remember { mutableStateOf<Links.Page?>(null) }
    var linkApps by remember { mutableStateOf(emptyList<TvLink.LinkApp>()) }
    var linkAppsLoading by remember { mutableStateOf(false) }
    var linkComponent by remember { mutableStateOf(prefs.getString("linkApp", null)) }
    var linkRun by remember { mutableIntStateOf(0) }     // "Check again"
    // A title page of another site (Trakt…, TitleSources): looked up (its IMDb id) before it's a title like any other;
    // an episode's link says which one.
    var sourceLink by remember { mutableStateOf<String?>(null) }
    var episodeKnown by remember { mutableStateOf(false) }

    val hostOk = host.trim().isNotEmpty()
    val idOk = Title.isImdbId(imdbId)
    val linkOk = link != null
    // How titles and links reach the TV: USB debugging first (Open with lists the TV's apps; Nuvio goes straight to
    // the streams), else pairing (the TV picks the app; Nuvio opens the title's page: nuvio://movie/tt…). Settings
    // can fix it to one. Checked again when the remote or Settings close (pairing and allowing happen there).
    var pairedRun by remember { mutableIntStateOf(0) }     // paired from the connect card
    val paired = remember(host.trim(), showRemote, showSettings, pairedRun) { hostOk && Atv.isPaired(context, host) }
    val linkVia = remember(host.trim(), showSettings) { Connection.link(context, host) }
    // Paired with this TV: keep the pairing by its name too, for when its address changes.
    LaunchedEffect(host.trim(), tvName, paired) { if (paired) Atv.rememberName(context, host, tvName) }
    var adb by remember { mutableStateOf<TvLink.Adb?>(null) }      // null: checking
    var adbRun by remember { mutableIntStateOf(0) }
    LaunchedEffect(host.trim(), adbRun, showRemote, showSettings) {
        adb = null
        if (host.isBlank()) return@LaunchedEffect
        delay(500)      // typing an address: wait for the whole of it
        adb = TvLink.check(context, host)
    }
    // Neither way works yet (not paired, USB debugging off or this phone not allowed): the connect card, first.
    val needsSetup = hostOk && linkVia == Connection.Via.AUTO && !paired && adb != null && adb != TvLink.Adb.ALLOWED
    // true: USB debugging; false: pairing; null: still checking, or not connected yet.
    val useAdb: Boolean? = when (linkVia) {
        Connection.Via.ADB -> true
        Connection.Via.PAIRING -> false
        Connection.Via.AUTO -> when {
            adb == null || needsSetup -> null
            adb == TvLink.Adb.ALLOWED -> true
            else -> false
        }
    }
    val linkByPairing = linkOk && useAdb == false
    val titleByPairing = idOk && !linkOk && useAdb == false
    // Where a title opens: "Nuvio" or "Stremio" (for the status line and the Activity log).
    val titleApp = if (useAdb == false) (if (pairedStremio) "Stremio" else "Nuvio")
        else apps.firstOrNull { it.component == appComponent }?.name ?: apps.firstOrNull()?.name ?: "Nuvio"
    val ready = hostOk && useAdb != null && (idOk || (linkOk && (linkApps.isNotEmpty() || linkByPairing))) && !busy
    val theTv = stringResource(R.string.the_tv)
    val tvLabel = tvName.ifEmpty { host.trim().ifEmpty { theTv } }

    // A TV picked: which Nuvio apps it has (connecting is also when it asks to allow this phone, the first time).
    LaunchedEffect(host.trim(), appsRun, useAdb) {
        apps = emptyList()
        appsError = null
        if (host.isBlank() || useAdb != true) return@LaunchedEffect
        appsLoading = true
        try {
            val found = TvLink.apps(context, host)
            apps = found
            if (found.none { it.component == appComponent }) appComponent = found.firstOrNull()?.component
            if (found.isEmpty()) appsError = context.getString(R.string.no_nuvio_app_install, tvLabel)
        } catch (e: Exception) {
            appsError = context.getString(R.string.couldnt_reach, tvLabel, e.message ?: e.javaClass.simpleName)
            Telemetry.error(context, "tv_apps", e)
        } finally {
            appsLoading = false
        }
    }

    /** `byPairing`: passed by the lookup, which knows before this composition does. */
    fun openLinkOnTv(byPairing: Boolean = linkByPairing) {
        val l = link ?: return
        busy = true
        failed = false
        status = context.getString(if (byPairing) R.string.connecting else R.string.connecting_adb)
        scope.launch {
            try {
                if (byPairing) Atv.openLink(context, host, Links.forTv(l)) else TvLink.openLink(context, host, l, linkComponent)
                val app = if (byPairing) null else (linkApps.firstOrNull { it.component == linkComponent } ?: linkApps.firstOrNull())?.name
                val p = page ?: Links.Page(linkTitle.ifBlank { Links.site(l) })
                library.useLink(l, p, app, played = true)
                prefs.edit().putString("host", host.trim()).putString("tvName", tvName).putString("linkApp", linkComponent).apply()
                status = if (app != null) context.getString(R.string.opened_link_in, p.title, app, tvLabel)
                    else context.getString(R.string.opened_link, p.title, tvLabel)
                ActivityLog.add(
                    context,
                    if (app != null) context.getString(R.string.log_link_app, Links.site(l), app) else context.getString(R.string.log_link, Links.site(l)),
                    if (byPairing) "Pairing" else "USB debugging",
                )
                Telemetry.event(context, "open_link", "site" to Links.site(l), "via" to (if (byPairing) "pairing" else "adb"), "ok" to true)
            } catch (e: Exception) {
                ActivityLog.add(context, context.getString(R.string.log_link, Links.site(l)), if (byPairing) "Pairing" else "USB debugging", ok = false)
                Telemetry.event(context, "open_link", "site" to Links.site(l), "via" to (if (byPairing) "pairing" else "adb"), "ok" to false)
                Telemetry.error(context, "open_link", e)
                failed = true
                status = context.getString(R.string.couldnt_open, e.message ?: e.javaClass.simpleName)
            } finally {
                busy = false
            }
        }
    }

    fun openOnTv() {
        if (link != null) return openLinkOnTv()
        busy = true
        failed = false
        val byPairing = titleByPairing
        val via = if (byPairing) "Pairing" else "USB debugging"
        status = context.getString(if (byPairing) R.string.connecting else R.string.connecting_adb)
        scope.launch {
            try {
                var n = name.trim()
                if (n.isEmpty()) {
                    // Nuvio needs the name for its stream picker (over pairing, only for history).
                    n = Meta.lookup(imdbId)?.name.orEmpty()
                    if (n.isEmpty() && !byPairing) error(context.getString(R.string.title_name_missing))
                    name = n
                }
                val title = Title(imdbId.trim(), n.ifEmpty { imdbId.trim() }, series, season, episode)
                if (byPairing) {
                    // Stremio's link goes to the episode's streams; Nuvio's, to the title's page.
                    Atv.openLink(context, host, if (pairedStremio) title.stremioLink(streams = true) else "nuvio://${if (series) "series" else "movie"}/${title.imdbId}")
                } else {
                    TvLink.open(context, host, title, appComponent)
                }
                library.use(title, meta, played = true)
                prefs.edit().putString("host", host.trim()).putString("tvName", tvName).putString("app", appComponent).apply()
                val withEpisode = title.name + if (series) " " + context.getString(R.string.episode_short, season, episode) else ""
                status = when {
                    byPairing && pairedStremio -> context.getString(R.string.opened_title_pick_stream, title.name, "Stremio", tvLabel)
                    byPairing -> context.getString(R.string.opened_title_pick_stream, title.name, "Nuvio", tvLabel)
                    titleApp == "Stremio" -> context.getString(R.string.opened_title_pick_stream, withEpisode, "Stremio", tvLabel)
                    else -> context.getString(R.string.playing_title, withEpisode, tvLabel)
                }
                ActivityLog.add(context, context.getString(R.string.log_title, titleApp, title.name), via)
                Telemetry.event(context, "play_title", "via" to (if (byPairing) "pairing" else "adb"), "series" to series, "ok" to true)
            } catch (e: Exception) {
                ActivityLog.add(context, context.getString(R.string.log_title, titleApp, name.trim().ifEmpty { imdbId }), via, ok = false)
                Telemetry.event(context, "play_title", "via" to (if (byPairing) "pairing" else "adb"), "series" to series, "ok" to false)
                Telemetry.error(context, "play_title", e)
                failed = true
                status = context.getString(R.string.couldnt_open, e.message ?: e.javaClass.simpleName)
            } finally {
                busy = false
            }
        }
    }

    /**
     * An entry from the library back in the remote, as it was used (or edited); `play`: straight to the TV. `from`:
     * "recent" (under the search box) or "library".
     */
    fun pick(e: Library.Entry, play: Boolean, from: String) {
        showLibrary = false
        Telemetry.event(context, "open_entry", "kind" to (if (e.link != null) "link" else "title"), "play" to play, "from" to from)
        sourceLink = null
        if (e.link != null) {
            link = e.link
            linkTitle = e.name
            recordLink = true
            imdbId = ""
            failed = false
            status = null
            // Played once the TV says which app opens it (the link effect).
            openWhenKnown = play
            shareRun++
            return
        }
        link = null
        imdbId = e.imdbId
        name = e.name
        autoName = false
        series = e.series
        keepType = true
        season = e.season
        episode = e.episode
        editName = false
        failed = false
        status = null
        if (play) {
            if (hostOk && !busy) openOnTv() else status = context.getString(R.string.pick_tv_then_play)
        }
    }

    // A shared IMDb page fills in the id (and the title, when the share says it); another site's, once it's looked up.
    val sharedSource = shared?.link?.let(TitleSources::of)
    if (shared != null && shared.link != null && sharedSource != null) {
        Telemetry.event(context, "share", "kind" to sharedSource.key)
        sourceLink = shared.link
        link = null
        imdbId = ""
        name = ""
        status = null
        failed = false
        openWhenKnown = true
        shareRun++
        onSharedUsed()
    } else if (shared != null && shared.link != null) {
        sourceLink = null
        Telemetry.event(context, "share", "kind" to "link", "site" to Links.site(shared.link))
        link = shared.link
        linkTitle = shared.name
        recordLink = true
        imdbId = ""
        status = null
        failed = false
        openWhenKnown = true
        shareRun++
        onSharedUsed()
    } else if (shared != null) {
        Telemetry.event(context, "share", "kind" to "title")
        sourceLink = null
        link = null
        imdbId = shared.imdbId
        if (shared.name.isNotEmpty()) {
            name = shared.name
            autoName = true
        }
        shared.series?.let { series = it }
        keepType = false
        status = null
        failed = false
        openWhenKnown = true
        shareRun++
        onSharedUsed()
    }

    // A link: its name and picture (the page, or the link itself), and which TV apps open it; shared: opened as soon
    // as there's an app for it.
    LaunchedEffect(link, shareRun) {
        page = null
        val l = link ?: return@LaunchedEffect
        if (!recordLink) delay(600)     // typing: wait for the whole link
        val p = Links.page(l, linkTitle)
        page = p
        if (recordLink) library.useLink(l, p, null, played = false)
    }
    LaunchedEffect(link, host.trim(), shareRun, linkRun, useAdb) {
        linkApps = emptyList()
        val l = link ?: return@LaunchedEffect
        if (host.isBlank() || useAdb == null) return@LaunchedEffect
        if (!useAdb) {
            // Over pairing: no app to look up, the TV picks it.
            if (openWhenKnown) {
                openWhenKnown = false
                if (!busy) openLinkOnTv(byPairing = true)
            }
            return@LaunchedEffect
        }
        delay(300)
        linkAppsLoading = true
        try {
            val found = TvLink.linkApps(context, host, l)
            linkApps = found
            if (found.none { it.component == linkComponent }) linkComponent = found.firstOrNull()?.component
        } catch (e: Exception) {
            failed = true
            status = context.getString(R.string.couldnt_reach, tvLabel, e.message ?: e.javaClass.simpleName)
            Telemetry.error(context, "link_apps", e)
        } finally {
            linkAppsLoading = false
        }
        if (openWhenKnown) {
            openWhenKnown = false
            if (linkApps.isNotEmpty() && !busy) openLinkOnTv(byPairing = false)
        }
    }

    // Another site's page: its IMDb id (and the episode, from the link), then the title as if its IMDb page was shared.
    // Not found: its name searched instead, the results under the box.
    LaunchedEffect(sourceLink, shareRun) {
        val l = sourceLink ?: return@LaunchedEffect
        val source = TitleSources.of(l) ?: return@LaunchedEffect
        if (!openWhenKnown) delay(600)     // typing: wait for the whole link
        lookingUp = true
        val found = try { source.resolve(l) } finally { lookingUp = false }
        Telemetry.event(context, "source_lookup", "source" to source.key, "ok" to (found != null))
        sourceLink = null
        if (found == null) {
            imdbId = source.searchFor(l).orEmpty()
            openWhenKnown = false
            status = context.getString(R.string.source_not_found, source.name)
            return@LaunchedEffect
        }
        val t = found.title
        imdbId = t.imdbId
        name = ""
        autoName = true
        series = t.series
        keepType = true
        season = t.season
        episode = t.episode
        episodeKnown = found.episodeKnown
        shareRun++
    }

    // The id gives the title, its art and whether it's a movie or a series (Cinemeta).
    LaunchedEffect(imdbId, shareRun) {
        val knownEpisode = episodeKnown
        episodeKnown = false
        notFound = false
        if (!Title.isImdbId(imdbId)) {
            meta = null
            return@LaunchedEffect
        }
        lookingUp = true
        delay(300)      // typing: wait for the whole id
        val found = Meta.lookup(imdbId)
        lookingUp = false
        meta = found
        Telemetry.event(context, "title_lookup", "ok" to (found != null))
        if (found == null) {
            notFound = true
            editName = true
            openWhenKnown = false
            return@LaunchedEffect
        }
        if (autoName || name.isBlank()) {
            name = found.name
            autoName = true
        }
        if (!keepType) series = found.series
        library.use(Title(imdbId, name, series, season, episode), found, played = false)
        if (openWhenKnown) {
            openWhenKnown = false
            when {
                found.series && !knownEpisode -> status = context.getString(R.string.pick_episode_then_play)
                hostOk && !busy -> openOnTv()
                else -> status = context.getString(R.string.pick_tv_then_play)
            }
        }
    }

    LaunchedEffect(showLibrary, showRemote, showSettings) {
        Telemetry.screen(context, when { showLibrary -> "library"; showRemote -> "remote"; showSettings -> "settings"; else -> "send" })
    }
    LaunchedEffect(openScreen) {
        val screen = openScreen ?: return@LaunchedEffect
        showLibrary = screen == "library"
        showSettings = screen == "settings" || screen == "activity"
        showRemote = screen == "remote"
        openActivity = screen == "activity"
        onOpenScreenUsed()
    }
    BackHandler(enabled = showLibrary || showRemote || showSettings) { showLibrary = false; showRemote = false; showSettings = false }
    // 0: send, 1: library, 2: remote
    AnimatedContent(targetState = if (showLibrary) 1 else if (showRemote) 2 else if (showSettings) 3 else 0, label = "screen") { screen ->
    if (screen == 1) {
        LibraryScreen(library, onBack = { showLibrary = false }, onOpen = { pick(it, false, "library") }, onPlay = { pick(it, true, "library") })
        return@AnimatedContent
    }
    if (screen == 2) {
        RemoteScreen(host.trim(), tvName, onBack = { showRemote = false })
        return@AnimatedContent
    }
    if (screen == 3) {
        SettingsScreen(host.trim(), tvName, onBack = { showSettings = false; openUpdate = false }, startOnActivity = openActivity, startOnUpdate = openUpdate)
        return@AnimatedContent
    }
    var showTvSheet by remember { mutableStateOf(false) }
    var showAppSheet by remember { mutableStateOf(false) }
    // The TV and how it's reached, said once: on the chip under the title.
    val tvStatus = when {
        hostOk -> stringResource(
            when {
                // Over pairing ("Pairing only" in Settings shows it before pairing, too).
                useAdb == false -> if (paired) R.string.tv_status_paired else R.string.tv_status_not_paired
                adb == null -> R.string.tv_status_checking
                adb == TvLink.Adb.ALLOWED -> R.string.tv_status_adb
                else -> R.string.tv_status_not_connected
            },
            tvLabel,
        )
        searching -> stringResource(R.string.looking_for_tvs)
        else -> stringResource(R.string.pick_a_tv)
    }
    val scroll = rememberScrollState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name), fontWeight = FontWeight.SemiBold) },
                actions = {
                    IconButton(onClick = { showLibrary = true }) { Icon(AppIcons.History, stringResource(R.string.history_and_saved)) }
                    // A dot on Settings when a newer Skiff is out (Settings → Update).
                    val dot by Updates.badge.collectAsState(initial = false)
                    IconButton(onClick = { showSettings = true }) {
                        BadgedBox(badge = { if (dot) Badge() }) {
                            Icon(Icons.Rounded.Settings, stringResource(if (dot) R.string.settings_update_available else R.string.settings))
                        }
                    }
                },
            )
        },
        bottomBar = {
            PlayBar(
                label = stringResource(R.string.play),     // the TV is named in the top bar
                enabled = ready,
                busy = busy,
                hint = when {
                    busy -> null
                    !hostOk -> stringResource(R.string.hint_pick_tv)
                    needsSetup -> stringResource(R.string.hint_connect, tvLabel)
                    linkByPairing -> null
                    linkOk && linkAppsLoading -> stringResource(R.string.hint_checking_link_app)
                    linkOk && linkApps.isEmpty() -> stringResource(R.string.no_app_for_link, tvLabel, link?.let(Links::site).orEmpty())
                    !idOk && !linkOk -> stringResource(R.string.hint_share)
                    else -> null
                },
                onClick = { openOnTv() },
                remoteEnabled = hostOk,
                onRemote = { showRemote = true },
            )
        },
    ) { inner ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(inner)
                .consumeWindowInsets(inner)     // the keyboard's room counts the bars' already given
                .imePadding()
                .verticalScroll(scroll)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // MARK: The TV: one chip; tap it for the TVs found, an address, searching again.
            Row(verticalAlignment = Alignment.CenterVertically) {
                AssistChip(
                    onClick = { showTvSheet = true },
                    label = { Text(tvStatus, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    leadingIcon = { Icon(AppIcons.Tv, null, Modifier.size(18.dp)) },
                    trailingIcon = { Icon(Icons.Rounded.ArrowDropDown, stringResource(R.string.change_tv), Modifier.size(20.dp)) },
                    shape = MaterialTheme.shapes.extraLarge,
                )
            }

            // MARK: Connect (the first time with a TV: pair it, or allow USB debugging)
            if (needsSetup) {
                PairCard(
                    host,
                    onPaired = { pairedRun++ },
                    title = stringResource(R.string.connect_to, tvLabel),
                    intro = if (adb == TvLink.Adb.NOT_ALLOWED) {
                        stringResource(R.string.connect_intro_not_allowed, tvLabel)
                    } else {
                        stringResource(R.string.connect_intro)
                    },
                    footer = {
                        Text(
                            stringResource(R.string.connect_footer),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        TextButton(onClick = { adbRun++ }) {
                            Icon(Icons.Rounded.Refresh, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.check_again))
                        }
                    },
                )
            }

            // MARK: What to watch: the search box first.
            val query = if (link == null && !Title.isImdbId(imdbId)) imdbId.trim() else ""
            LaunchedEffect(query, searchNow) {
                if (query.length < 2) { hits = emptyList(); hitsFor = ""; findingTitles = false; return@LaunchedEffect }
                if (hitsFor == query && hits.isNotEmpty()) return@LaunchedEffect     // Search pressed: already found
                if (searchNow == searchedNow) delay(350)      // typing: search once the word is there
                searchedNow = searchNow
                findingTitles = true
                val found = Meta.search(query)
                hits = found
                hitsFor = query
                shownHits = SEARCH_PAGE
                findingTitles = false
                // How many were found, never what was typed.
                Telemetry.event(context, "title_search", "results" to found.size)
            }
            // Near the end of the page with more found than shown: the next page.
            val nearEnd = with(LocalDensity.current) { 480.dp.roundToPx() }
            LaunchedEffect(scroll) {
                snapshotFlow { Triple(scroll.maxValue - scroll.value, shownHits, hits.size) }.collect { (left, shown, all) ->
                    if (hitsFor.isNotEmpty() && shown < all && left < nearEnd) {
                        shownHits = shown + SEARCH_PAGE
                        Telemetry.event(context, "search_more", "shown" to minOf(shownHits, all))
                    }
                }
            }
            OutlinedTextField(
                value = sourceLink ?: link ?: imdbId,
                onValueChange = { v ->
                    // Another site's title page, once looked up; an IMDb link or id: the Nuvio flow; any other link:
                    // the app on the TV that opens it.
                    val id = Title.idIn(v)
                    sourceLink = null
                    when {
                        TitleSources.of(v) != null -> { link = null; imdbId = ""; sourceLink = v.trim(); openWhenKnown = false }
                        id != null -> { link = null; imdbId = id; keepType = false }
                        Links.isLink(v.trim()) -> { link = v.trim(); linkTitle = ""; recordLink = false; imdbId = "" }
                        else -> { link = null; imdbId = v; keepType = false }     // as typed: trimming ate the space between words
                    }
                },
                placeholder = { Text(stringResource(R.string.search_placeholder)) },
                leadingIcon = { Icon(Icons.Rounded.Search, null) },
                isError = imdbId.lowercase().startsWith("tt") && imdbId.drop(2).all { it.isDigit() } && imdbId.length > 2 && !idOk,
                singleLine = true,
                shape = MaterialTheme.shapes.extraLarge,
                trailingIcon = {
                    if (imdbId.isNotEmpty() || link != null || sourceLink != null) {
                        // Start over: the box, the title or link found, its episode, and the last message.
                        IconButton(onClick = {
                    link = null
                    sourceLink = null
                    linkTitle = ""
                    recordLink = false
                    page = null
                    imdbId = ""
                    name = ""
                    meta = null
                    series = false
                    season = 1
                    episode = 1
                    autoName = true
                    keepType = false
                    editName = false
                    notFound = false
                    openWhenKnown = false
                    status = null
                    failed = false
                    hits = emptyList()
                    hitsFor = ""
                    Telemetry.event(context, "clear_input")
                        }) { Icon(Icons.Rounded.Close, stringResource(R.string.clear)) }
                    } else {
                        TextButton(onClick = {
                            clipboard.getText()?.text?.let { t ->
                                val id = Title.idIn(t)
                                val l = Links.linkIn(t)
                                val source = l?.let(TitleSources::of)
                                when {
                                    source != null -> { link = null; imdbId = ""; sourceLink = l; openWhenKnown = false }
                                    id != null -> { link = null; imdbId = id; autoName = true; keepType = false }
                                    l != null -> { link = l; linkTitle = ""; recordLink = true; imdbId = "" }
                                }
                                Telemetry.event(context, "paste", "kind" to when { source != null -> source.key; id != null -> "title"; l != null -> "link"; else -> "none" })
                            }
                        }) { Text(stringResource(R.string.paste)) }
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = {
                    keyboard?.hide()        // the results under the box, in view
                    if (query.length >= 2) searchNow++
                }),
                modifier = Modifier.fillMaxWidth(),
            )

            // A search: the titles found, one tap fills it in (as a shared IMDb page does).
            if (query.length >= 2) {
                val current = hitsFor == query
                when {
                    current && hits.isNotEmpty() -> for ((i, h) in hits.take(shownHits).withIndex()) {
                        SearchHitRow(h) {
                            Telemetry.event(context, "search_pick", "position" to i, "series" to h.series)
                            imdbId = h.imdbId
                            name = h.name
                            series = h.series
                            autoName = true
                            keepType = false
                            hits = emptyList()
                            hitsFor = ""
                            status = null
                        }
                    }
                    findingTitles || !current -> Row(verticalAlignment = Alignment.CenterVertically) {
                        LoadingIndicator(Modifier.size(32.dp))
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(R.string.searching), style = MaterialTheme.typography.bodyMedium)
                    }
                    else -> Text(
                        stringResource(R.string.no_title_called, query),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Nothing entered: the last few used, one tap from the TV.
            val recent = entries.filter { it.inHistory }.take(3)
            if (!idOk && !linkOk && query.length < 2 && recent.isNotEmpty()) {
                SectionHeader(stringResource(R.string.recent)) {
                    TextButton(onClick = { showLibrary = true }) { Text(stringResource(R.string.see_all)) }
                }
                for (e in recent) {
                    EntryRow(
                        e,
                        onOpen = { pick(e, false, "recent") },
                        onPlay = { pick(e, true, "recent") },
                        onToggleSaved = {
                            library.setSaved(e.title(), null, !e.saved)
                            Telemetry.event(context, "save", "kind" to (if (e.link != null) "link" else "title"), "on" to !e.saved, "from" to "recent")
                        },
                    )
                }
            }

            if (linkOk) {
                val l = link!!
                LinkCard(page, Links.site(l), loading = page == null)
                val savedNow = entries.any { it.imdbId == l && it.saved }
                ToggleButton(
                    checked = savedNow,
                    onCheckedChange = { on ->
                        library.setLinkSaved(l, page, linkApps.firstOrNull { it.component == linkComponent }?.name, on)
                        Telemetry.event(context, "save", "kind" to "link", "on" to on, "from" to "send")
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(if (savedNow) AppIcons.Bookmark else AppIcons.BookmarkBorder, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(if (savedNow) R.string.saved_for_later else R.string.save_for_later))
                }
            }

            AnimatedContent(targetState = Triple(meta, lookingUp, idOk), label = "title") { (m, looking, valid) ->
                when {
                    looking -> Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                        LoadingIndicator()
                    }
                    m != null -> TitleCard(m)
                    valid && notFound -> NoteCard(Icons.Rounded.Warning, stringResource(R.string.not_on_cinemeta), error = true)
                    else -> Spacer(Modifier.height(0.dp))
                }
            }

            if (idOk && (meta != null || name.isNotBlank())) {
                val savedNow = entries.any { it.imdbId == imdbId && it.saved }
                ToggleButton(
                    checked = savedNow,
                    onCheckedChange = { on ->
                        library.setSaved(Title(imdbId, name.ifBlank { meta?.name.orEmpty() }, series, season, episode), meta, on)
                        Telemetry.event(context, "save", "kind" to "title", "on" to on, "from" to "send")
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(if (savedNow) AppIcons.Bookmark else AppIcons.BookmarkBorder, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(if (savedNow) R.string.saved_for_later else R.string.save_for_later))
                }
            }

            if (idOk) {
                // Movie or series: set by the lookup, yours to change.
                Row(horizontalArrangement = Arrangement.spacedBy(ButtonGroupDefaults.ConnectedSpaceBetween)) {
                    ToggleButton(
                        checked = !series,
                        onCheckedChange = { series = false; keepType = true },
                        shapes = ButtonGroupDefaults.connectedLeadingButtonShapes(),
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(AppIcons.Movie, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.movie))
                    }
                    ToggleButton(
                        checked = series,
                        onCheckedChange = { series = true; keepType = true },
                        shapes = ButtonGroupDefaults.connectedTrailingButtonShapes(),
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(AppIcons.Series, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.series))
                    }
                }
            }

            AnimatedVisibility(visible = idOk && series, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Stepper(stringResource(R.string.season), season, { season = it }, Modifier.weight(1f))
                    Stepper(stringResource(R.string.episode), episode, { episode = it }, Modifier.weight(1f))
                }
            }

            if (idOk) {
                AnimatedVisibility(visible = editName || notFound) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it; autoName = false },
                        label = { Text(stringResource(R.string.name_shown_in_nuvio)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.large,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (!editName && !notFound) {
                    TextButton(onClick = { editName = true }) {
                        Icon(Icons.Rounded.Edit, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.edit_the_name))
                    }
                }
            }


            // MARK: Open with: one line under the title or link; tap it to choose (over USB debugging).
            if (hostOk && (idOk || linkOk)) {
                val chosen = if (linkOk) linkApps.firstOrNull { it.component == linkComponent }?.name ?: linkApps.firstOrNull()?.name
                    else apps.firstOrNull { it.component == appComponent }?.let { listOfNotNull(it.name, it.version).joinToString(" ") }
                val loading = if (linkOk) linkAppsLoading else appsLoading
                val line = when {
                    useAdb == false -> if (linkOk) stringResource(R.string.opens_in_tv_app_for, link?.let(Links::site).orEmpty())
                        else stringResource(if (pairedStremio) R.string.opens_in_stremio_streams else R.string.opens_in_nuvio_page)
                    useAdb == null -> null
                    loading -> stringResource(R.string.checking_which_app)
                    chosen != null -> stringResource(R.string.opens_in, chosen)
                    linkOk -> stringResource(R.string.no_app_for_link, tvLabel, link?.let(Links::site).orEmpty())
                    else -> appsError ?: stringResource(R.string.no_nuvio_app, tvLabel)
                }
                val pairedChoice = useAdb == false && !linkOk      // Nuvio or Stremio, over pairing
                val choosable = pairedChoice || useAdb == true && !loading && (if (linkOk) linkApps.size else apps.size) > 1
                val problem = useAdb == true && !loading && chosen == null
                if (line != null) {
                    Surface(
                        onClick = { showAppSheet = true },
                        enabled = pairedChoice || useAdb == true && !loading,
                        shape = MaterialTheme.shapes.large,
                        color = if (problem) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainer,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (loading) LoadingIndicator(Modifier.size(22.dp)) else Icon(AppIcons.Tv, null, Modifier.size(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Text(line, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            if (choosable || problem) Icon(Icons.Rounded.ArrowDropDown, stringResource(R.string.choose_the_app))
                        }
                    }
                }
            }

            AnimatedContent(targetState = status to failed, label = "status") { (s, bad) ->
                if (s != null) NoteCard(if (bad) Icons.Rounded.Warning else Icons.Rounded.Info, s, error = bad)
            }

            Text(
                stringResource(R.string.same_wifi),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        }
    }

    // The TVs: those found on the Wi-Fi, an address typed in, searching again.
    if (showTvSheet) {
        ModalBottomSheet(onDismissRequest = { showTvSheet = false }) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SectionHeader(stringResource(R.string.your_tv)) {
                    if (!searching) {
                        TextButton(onClick = { finder.start(); searchRun++ }) {
                            Icon(Icons.Rounded.Refresh, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.search_again))
                        }
                    }
                }
                if (tvs.isEmpty()) {
                    Surface(
                        shape = MaterialTheme.shapes.extraLarge,
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (searching) LoadingIndicator(Modifier.size(40.dp))
                            else Icon(AppIcons.Tv, null, Modifier.size(32.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.width(16.dp))
                            Text(
                                stringResource(if (searching) R.string.looking_for_tvs_wifi else R.string.no_tv_found),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        }
                    }
                }
                for (tv in tvs) {
                    TvCard(
                        tv = tv,
                        selected = tv.host == host.trim(),
                        paired = Atv.isPaired(context, tv.host),
                        onClick = {
                            // Without USB debugging too: it can be paired (the remote shows how).
                            host = tv.host
                            tvName = tv.name
                            manual = false
                            showTvSheet = false
                            Telemetry.event(context, "pick_tv", "found" to tvs.size, "ready" to tv.ready, "paired" to Atv.isPaired(context, tv.host))
                        },
                    )
                }
                AnimatedVisibility(visible = manual || (!searching && tvs.none { it.ready })) {
                    OutlinedTextField(
                        value = host,
                        onValueChange = { host = it; tvName = "" },
                        label = { Text(stringResource(R.string.tv_address)) },
                        placeholder = { Text("192.168.1.7") },
                        supportingText = { Text(stringResource(R.string.tv_address_help)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.large,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (!manual && tvs.any { it.ready }) {
                    TextButton(onClick = { manual = true; Telemetry.event(context, "manual_address") }) { Text(stringResource(R.string.enter_address_instead)) }
                }

            }
        }
    }

    // Open with: the TV's apps for this title or link (over USB debugging).
    if (showAppSheet) {
        ModalBottomSheet(onDismissRequest = { showAppSheet = false }) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SectionHeader(stringResource(R.string.open_with)) {
                    if (useAdb == true) TextButton(onClick = { adbRun++; if (linkOk) linkRun++ else appsRun++ }) {
                        Icon(Icons.Rounded.Refresh, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.check_again))
                    }
                }
                if (useAdb == false && !linkOk) {
                    // Paired: the TV doesn't say which apps it has, so these are what Skiff knows how to open.
                    AppCard(
                        "Nuvio", stringResource(R.string.app_nuvio_subtitle),
                        selected = !pairedStremio, onClick = { pairedStremio = false; showAppSheet = false },
                    )
                    AppCard(
                        "Stremio", stringResource(R.string.app_stremio_subtitle),
                        selected = pairedStremio, onClick = { pairedStremio = true; showAppSheet = false },
                    )
                } else if (linkOk) {
                    when {
                        linkAppsLoading -> Surface(
                            shape = MaterialTheme.shapes.extraLarge,
                            color = MaterialTheme.colorScheme.surfaceContainer,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                                LoadingIndicator(Modifier.size(40.dp))
                                Spacer(Modifier.width(16.dp))
                                Text(stringResource(R.string.checking_link_app_on, tvLabel), style = MaterialTheme.typography.bodyLarge)
                            }
                        }
                        linkApps.isEmpty() -> NoteCard(
                            Icons.Rounded.Warning,
                            stringResource(R.string.no_app_for_link_install, tvLabel, link?.let(Links::site).orEmpty()),
                            error = true,
                        )
                        else -> for (app in linkApps) {
                            AppCard(
                                app.name, app.pkg,
                                selected = app.component == linkComponent, onClick = { linkComponent = app.component; showAppSheet = false },
                            )
                        }
                    }
                } else {
                    when {
                        appsLoading -> Surface(
                            shape = MaterialTheme.shapes.extraLarge,
                            color = MaterialTheme.colorScheme.surfaceContainer,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                                LoadingIndicator(Modifier.size(40.dp))
                                Spacer(Modifier.width(16.dp))
                                Text(
                                    stringResource(R.string.checking_apps_on, tvLabel),
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                            }
                        }
                        appsError != null -> NoteCard(Icons.Rounded.Warning, appsError!!, error = true)
                        else -> for (app in apps) {
                            AppCard(
                                listOfNotNull(app.name, app.version).joinToString(" · "), "${app.source} · ${app.pkg}",
                                selected = app.component == appComponent, onClick = { appComponent = app.component; showAppSheet = false },
                            )
                        }
                    }
                }
            }
        }
    }
    }
}

@Composable
private fun SectionHeader(text: String, action: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary, modifier = Modifier.weight(1f),
        )
        action()
    }
}

/** A TV: its name and address; the selected one gets the expressive cookie badge and the primary container. */
/** A title found by search: poster, name, movie or series and year; tap to fill it in. */
@Composable
private fun SearchHitRow(h: Meta.Hit, onPick: () -> Unit) {
    Card(
        onClick = onPick,
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.width(46.dp).height(68.dp).clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.secondaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(if (h.series) AppIcons.Series else AppIcons.Movie, null, tint = MaterialTheme.colorScheme.onSecondaryContainer)
                if (h.poster != null) {
                    AsyncImage(model = h.poster, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
                }
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(h.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(
                    listOfNotNull(stringResource(if (h.series) R.string.series else R.string.movie), h.year).joinToString(" · "),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun TvCard(tv: TvFinder.Tv, selected: Boolean, paired: Boolean, onClick: () -> Unit) {
    val container by animateColorAsState(
        if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
        label = "tv",
    )
    Card(
        onClick = onClick,
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = container),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(52.dp)
                    .clip(if (selected) MaterialShapes.Cookie9Sided.toShape() else MaterialShapes.Circle.toShape())
                    .background(if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    AppIcons.Tv, null, Modifier.size(26.dp),
                    tint = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(tv.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    when {
                        tv.ready -> tv.host
                        paired -> stringResource(R.string.tv_host_paired, tv.host)
                        else -> stringResource(R.string.tv_host_pair_from_remote, tv.host)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (selected) Icon(Icons.Rounded.Check, stringResource(R.string.selected), tint = MaterialTheme.colorScheme.primary)
        }
    }
}

/** A TV app to open in: a Nuvio build or Stremio (version, where it came from), or the app for a link; the picked one gets the cookie badge. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun AppCard(title: String, subtitle: String, selected: Boolean, onClick: () -> Unit) {
    val container by animateColorAsState(
        if (selected) MaterialTheme.colorScheme.tertiaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
        label = "app",
    )
    Card(
        onClick = onClick,
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = container),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(52.dp)
                    .clip(if (selected) MaterialShapes.Cookie9Sided.toShape() else MaterialShapes.Circle.toShape())
                    .background(if (selected) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.secondaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.PlayArrow, null, Modifier.size(28.dp),
                    tint = if (selected) MaterialTheme.colorScheme.onTertiary else MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (selected) Icon(Icons.Rounded.Check, stringResource(R.string.selected), tint = MaterialTheme.colorScheme.tertiary)
        }
    }
}

/** A link: its picture (when the page has one), its name, and the site. */
@Composable
private fun LinkCard(page: Links.Page?, site: String, loading: Boolean) {
    Card(shape = MaterialTheme.shapes.extraLarge, modifier = Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().heightIn(min = 140.dp)) {
            val image = page?.image
            if (image != null) {
                AsyncImage(model = image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
                Box(
                    Modifier.matchParentSize().background(
                        Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.35f))),
                    ),
                )
            }
            val onArt = if (image != null) Color.White else MaterialTheme.colorScheme.onSurface
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (loading) {
                    LoadingIndicator(Modifier.size(40.dp))
                } else {
                    Text(
                        page?.title.orEmpty(), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                        color = onArt, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill(site)
                    page?.by?.let { Pill(it) }
                }
            }
        }
    }
}

/** The title from Cinemeta: its backdrop behind, the poster, then year · genres · rating · runtime. */
@Composable
private fun TitleCard(m: Meta.Found) {
    Card(shape = MaterialTheme.shapes.extraLarge, modifier = Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().heightIn(min = 180.dp)) {
            if (m.background != null) {
                AsyncImage(
                    model = m.background, contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.matchParentSize(),
                )
                Box(
                    Modifier.matchParentSize().background(
                        Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.35f))),
                    ),
                )
            }
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                if (m.poster != null) {
                    AsyncImage(
                        model = m.poster, contentDescription = null, contentScale = ContentScale.Crop,
                        modifier = Modifier.width(96.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(16.dp)),
                    )
                    Spacer(Modifier.width(16.dp))
                }
                val onArt = if (m.background != null) Color.White else MaterialTheme.colorScheme.onSurface
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        m.name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                        color = onArt, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    )
                    val details = listOfNotNull(m.year, m.genres.takeIf { it.isNotEmpty() }?.joinToString(", "), m.runtime)
                    if (details.isNotEmpty()) {
                        Text(details.joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = onArt.copy(alpha = 0.85f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Pill(stringResource(if (m.series) R.string.series else R.string.movie))
                        m.rating?.let { Pill("★ $it") }
                    }
                }
            }
        }
    }
}

@Composable
private fun Pill(text: String) {
    Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.primaryContainer) {
        Text(
            text, Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer,
        )
    }
}

/** Season or episode: − number +. */
@Composable
private fun Stepper(label: String, value: Int, onChange: (Int) -> Unit, modifier: Modifier = Modifier) {
    Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = modifier) {
        Column(Modifier.padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilledTonalIconButton(onClick = { if (value > 1) onChange(value - 1) }, enabled = value > 1) {
                    Text("−", style = MaterialTheme.typography.titleLarge)
                }
                AnimatedContent(targetState = value, label = label) { v ->
                    Text(
                        "$v", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 12.dp),
                    )
                }
                FilledTonalIconButton(onClick = { onChange(value + 1) }) {
                    Text("+", style = MaterialTheme.typography.titleLarge)
                }
            }
        }
    }
}

@Composable
private fun NoteCard(icon: ImageVector, text: String, error: Boolean) {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = if (error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                icon, null,
                tint = if (error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSecondaryContainer,
            )
            Spacer(Modifier.width(12.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** The one action, always at hand: a large expressive button (its shape morphs when pressed). */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun PlayBar(
    label: String,
    enabled: Boolean,
    busy: Boolean,
    hint: String?,
    onClick: () -> Unit,
    remoteEnabled: Boolean,
    onRemote: () -> Unit,
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, tonalElevation = 3.dp) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val height = ButtonDefaults.LargeContainerHeight
            // The remote beside Play: the two things done with the TV.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledTonalIconButton(onClick = onRemote, enabled = remoteEnabled, modifier = Modifier.size(height)) {
                    Icon(AppIcons.Remote, stringResource(R.string.remote), Modifier.size(ButtonDefaults.iconSizeFor(height)))
                }
                Button(
                    onClick = onClick,
                    enabled = enabled,
                    shapes = ButtonDefaults.shapes(),
                    contentPadding = ButtonDefaults.contentPaddingFor(height),
                    modifier = Modifier.weight(1f).heightIn(min = height),
                ) {
                    if (busy) {
                        LoadingIndicator(Modifier.size(ButtonDefaults.iconSizeFor(height)), color = MaterialTheme.colorScheme.onPrimary)
                    } else {
                        Icon(Icons.Rounded.PlayArrow, null, Modifier.size(ButtonDefaults.iconSizeFor(height)))
                    }
                    Spacer(Modifier.width(ButtonDefaults.iconSpacingFor(height)))
                    Text(label, style = ButtonDefaults.textStyleFor(height), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (hint != null) {
                Text(
                    hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}
