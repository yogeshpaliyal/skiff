package dev.skiff

import android.content.Context
import dadb.AdbKeyPair
import dadb.Dadb
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Talks to the TV over Wi-Fi, through its own ADB (port 5555), as `adb shell` would from a computer:
 *  - apps: the Nuvio apps on the TV (the Play Store and GitHub builds, and forks), from what Android says handles
 *    their intents;
 *  - open: a title in one of them. Nuvio has no link for a title: it reads these extras (the ones it writes to its own
 *    "Continue Watching" row), and with launchMode=stream (and a name) it goes straight to the stream picker.
 *
 * The phone has its own ADB key, made once: the first time, the TV asks "Allow USB debugging?" for it.
 */
object TvLink {
    private const val PORT = 5555
    /** Nuvio's activity: forks that renamed the app (and even the scheme) usually keep the code, and this class. */
    /** Between two answers in one shell call (not "#": query-activities prints "Activity #0:"). */
    private const val SPLIT = "--8<--skiff--8<--"
    private const val NUVIO_CLASS = "com.nuvio.tv.MainActivity"

    /**
     * An app on the TV to open titles in: a Nuvio build, or `stremio` (Stremio, which takes its own links rather than
     * Nuvio's extras). `component` is what to start ("com.nuvio.app/com.nuvio.tv.MainActivity").
     */
    data class NuvioApp(val pkg: String, val component: String, val version: String?, val source: String, val stremio: Boolean = false) {
        val name: String get() = if (stremio) "Stremio" else if (pkg.startsWith("com.nuvio.")) "Nuvio" else pkg
    }

    private fun keyPair(context: Context): AdbKeyPair {
        val private = File(context.filesDir, "adbkey")
        val public = File(context.filesDir, "adbkey.pub")
        if (!private.exists() || !public.exists()) AdbKeyPair.generate(private, public)
        return AdbKeyPair.read(private, public)
    }

    /**
     * One connection at a time: two at once, the first time, make the TV ask twice; it shows one prompt, and the other
     * connection would wait for an answer that never comes.
     */
    private val lock = Mutex()

    /** 5 s to reach the TV; 60 s for an answer (time to allow this phone on the TV, the first time). */
    private fun connect(context: Context, host: String, answer: Int = 60_000) =
        Dadb.create(host.trim(), PORT, keyPair(context), 5_000, answer)

    private suspend fun <T> withTv(context: Context, host: String, block: (Dadb) -> T): T =
        lock.withLock { withContext(Dispatchers.IO) { connect(context, host).use(block) } }

    /** USB debugging on the TV, for this phone: allowed, on but this phone not allowed (yet), or off. */
    enum class Adb { ALLOWED, NOT_ALLOWED, OFF }

    /**
     * Off the main thread. A quick look (a few seconds at most): the port shut is OFF; open but no answer to this
     * phone's key is NOT_ALLOWED (the TV then shows "Allow USB debugging?": allowed there, the next check passes).
     */
    suspend fun check(context: Context, host: String): Adb = if (Demo.on) Adb.ALLOWED else lock.withLock {
        withContext(Dispatchers.IO) {
            val open = runCatching { java.net.Socket().use { it.connect(java.net.InetSocketAddress(host.trim(), PORT), 2_000) } }.isSuccess
            if (!open) return@withContext Adb.OFF
            runCatching { connect(context, host, answer = 4_000).use { it.shell("true") } }
                .fold(onSuccess = { Adb.ALLOWED }, onFailure = { Adb.NOT_ALLOWED })
        }
    }

    /** Off the main thread. A shell command on the TV, as `adb shell` runs it (Settings → ADB tools). */
    suspend fun shell(context: Context, host: String, command: String): dadb.AdbShellResponse =
        if (Demo.on) dadb.AdbShellResponse("package:com.google.android.youtube.tv\npackage:in.startv.hotstar\npackage:com.nuvio.tv\n", "", 0)
        else withTv(context, host) { it.shell(command) }

    /**
     * Off the main thread. Installs an APK on the TV (as `adb install -r`; up to 5 minutes for the TV to answer: big
     * apps take a while). Throws with the TV's reason when it refuses (a different signature, too old an Android…).
     */
    suspend fun install(context: Context, host: String, apk: File): Unit = if (Demo.on) delay(1_200) else lock.withLock {
        withContext(Dispatchers.IO) { connect(context, host, answer = 300_000).use { it.install(apk, "-r") } }
    }

    /** Off the main thread. The Nuvio apps on that TV, the TV build first, then Stremio. Throws when the TV can't be reached. */
    suspend fun apps(context: Context, host: String): List<NuvioApp> =
        if (Demo.on) Demo.nuvioApps() else withTv(context, host) { tv -> detect(context, tv) }

    /**
     * What Android says opens `nuvio://` (Nuvio's own scheme: every build, and forks that kept it), plus what opens
     * `stremio://` with Nuvio's activity class (forks with their own scheme). The other apps opening stremio:// are
     * Stremio itself (`stremio`: opened with its own link instead of Nuvio's extras).
     */
    private fun detect(context: Context, tv: Dadb): List<NuvioApp> {
        val query = "cmd package query-activities --brief -a android.intent.action.VIEW -d"
        val out = tv.shell("$query nuvio://open; echo '$SPLIT'; $query stremio://open").output
        val nuvio = components(out.substringBefore(SPLIT))
        val (forks, stremio) = components(out.substringAfter(SPLIT, "")).partition { it.substringAfter('/') == NUVIO_CLASS }
        val byPkg = LinkedHashMap<String, String>()
        for (c in nuvio + forks + stremio) byPkg.putIfAbsent(c.substringBefore('/'), c)
        return byPkg.map { (pkg, component) ->
            val info = tv.shell("dumpsys package $pkg | grep -E 'versionName=|installerPackageName='").output
            NuvioApp(
                pkg = pkg,
                component = component,
                version = Regex("""versionName=(\S+)""").find(info)?.groupValues?.get(1),
                source = source(context, Regex("""installerPackageName=(\S+)""").find(info)?.groupValues?.get(1)),
                stremio = component.substringAfter('/') != NUVIO_CLASS && component !in nuvio,
            )
        }.sortedBy { if (it.pkg == "com.nuvio.tv") 0 else if (it.stremio) 2 else 1 }
    }

    /**
     * The remote: one connection kept open while it's showing (a new one per key would cost the handshake every
     * press), and the keys sent in order, one at a time. `cmd input` (about 90 ms on the TV) rather than `input`
     * (about 130 ms: it starts a Java process). Close it when the remote goes away.
     */
    class Remote internal constructor(private val tv: Dadb) : TvKeys {
        private val order = Mutex()

        /** A key (KeyEvent.KEYCODE_*); `long` for a long press. */
        override suspend fun key(code: Int) = key(code, false)

        suspend fun key(code: Int, long: Boolean) = run("cmd input keyevent ${if (long) "--longpress " else ""}$code")

        /** Text into the TV's focused field (a search box): spaces as %s, as `input text` wants them. */
        override suspend fun text(s: String) = run("cmd input text " + q(s.replace(" ", "%s")))

        private suspend fun run(command: String) {
            order.withLock { withContext(Dispatchers.IO) { tv.shell(command) } }
        }

        override val hasCursor = true

        /**
         * The pointer: a USB mouse made up on the TV with Android's `hid` command (Android 9 and later: what its own
         * tests plug in), opened at the first move and kept while the remote is. Its reports go to the command's input
         * as they come; the TV draws the pointer, as for a real mouse, and the mouse goes away with the connection.
         */
        private var hid: dadb.AdbShellStream? = null
        private val pointer = Mutex()

        override suspend fun mouse(dx: Int, dy: Int, buttons: Int, wheel: Int) = pointer.withLock {
            withContext(Dispatchers.IO) {
                val m = hid ?: tv.openShell("hid -").also {
                    it.write("""{"id":1,"command":"register","name":"Skiff cursor","vid":0x1209,"pid":0x0001,"bus":"usb","descriptor":[$MOUSE]}""" + "\n")
                    hid = it
                }
                try {
                    // A report moves at most 127 either way: a bigger move goes as several.
                    var x = dx
                    var y = dy
                    var w = wheel
                    do {
                        val sx = x.coerceIn(-127, 127)
                        val sy = y.coerceIn(-127, 127)
                        val sw = w.coerceIn(-127, 127)
                        m.write("""{"id":1,"command":"report","report":[$buttons,${sx and 0xff},${sy and 0xff},${sw and 0xff}]}""" + "\n")
                        x -= sx
                        y -= sy
                        w -= sw
                    } while (x != 0 || y != 0 || w != 0)
                } catch (e: Exception) {
                    // The TV ended the command: a new mouse at the next move.
                    runCatching { m.close() }
                    hid = null
                    throw e
                }
            }
        }

        override fun close() {
            runCatching { hid?.close() }
            runCatching { tv.close() }
        }
    }

    /**
     * A mouse's HID report descriptor: three buttons, then X, Y and the wheel, each a relative byte. Its reports are
     * those four bytes.
     */
    private val MOUSE = listOf(
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0, 0xC0,
    ).joinToString(",") { "0x%02x".format(it) }

    /** Off the main thread. A connected remote (it asks the TV to allow this phone, the first time). */
    suspend fun remote(context: Context, host: String): Remote = lock.withLock {
        withContext(Dispatchers.IO) {
            val tv = connect(context, host)
            try {
                tv.shell("true")    // connects now: the first key shouldn't wait for it
                Remote(tv)
            } catch (e: Exception) {
                runCatching { tv.close() }
                throw e
            }
        }
    }

    /** A TV app that opens a link (JioHotstar, YouTube…). */
    data class LinkApp(val pkg: String, val component: String) {
        val name: String get() = Links.appName(pkg)
    }

    /**
     * Off the main thread. The TV apps that open `link` (as the TV app wants it: Links.forTv), without the ones that
     * open any web page (browsers, the Downloader app, the system's browser stub): those aren't "the app for it".
     */
    suspend fun linkApps(context: Context, host: String, link: String): List<LinkApp> {
        val type = Streams.type(link)
        return if (Demo.on) Demo.linkApps(link, type) else withTv(context, host) { tv -> linkAppsOn(tv, Links.forTv(link), type) }
    }

    /**
     * `type`: a stream's ("video/ *", Streams), asked with it as well: the TV's players open a stream's link only when
     * told what it is, and no app but a browser says it opens it by the link alone.
     */
    private fun linkAppsOn(tv: Dadb, link: String, type: String?): List<LinkApp> {
        val query = "cmd package query-activities --brief -a android.intent.action.VIEW -d"
        val typed = if (type != null) "; echo '$SPLIT'; $query ${q(link)} -t ${q(type)}" else ""
        val out = tv.shell("$query 'https://example.com/'; echo '$SPLIT'; $query ${q(link)}$typed").output
        val parts = out.split(SPLIT)
        val generic = components(parts[0]).toSet()
        val apps = (components(parts.getOrNull(2).orEmpty()) + components(parts.getOrNull(1).orEmpty()))
            .filter { it !in generic }
            .distinctBy { it.substringBefore('/') }
            .map { LinkApp(it.substringBefore('/'), it) }
        return if (type != null) Streams.preferred(apps) { it.pkg } else Rules.preferred(link, apps) { it.pkg }
    }

    /**
     * Off the main thread. Opens `link` on the TV in `component` (null = the first app that opens it), started with its
     * rule's flags: by default a fresh start of its screen (NEW_TASK | CLEAR_TASK), so an app already open, like
     * JioHotstar, reads the link instead of just coming to the front.
     */
    suspend fun openLink(context: Context, host: String, link: String, component: String?): String {
        if (Demo.on) { delay(600); return "" }
        val type = Streams.type(link)
        return withTv(context, host) { tv ->
            val tvLink = Links.forTv(link)
            val apps = linkAppsOn(tv, tvLink, type)
            val target = apps.firstOrNull { it.component == component } ?: apps.firstOrNull()
                ?: error(context.getString(if (type != null) R.string.tv_no_player else R.string.tv_no_app_for_link, Links.site(link)))
            val r = tv.shell(linkCommand(tvLink, target.component, Rules.flags(link), type))
            val out = r.allOutput.trim()
            if (r.exitCode != 0 || out.contains("Error")) error(out.ifEmpty { context.getString(R.string.tv_said_no, r.exitCode) })
            out
        }
    }

    /** The shell command that opens a link in an app; a stream's with its type (VLC reads it as a video, not a page). */
    fun linkCommand(link: String, component: String, flags: Int, type: String?): String =
        "am start -a android.intent.action.VIEW -d ${q(link)}" + (if (type != null) " -t ${q(type)}" else "") +
            " -n ${q(component)} -f 0x" + Integer.toHexString(flags)

    /** "com.nuvio.tv/.MainActivity" → "com.nuvio.tv/com.nuvio.tv.MainActivity", from query-activities' lines. */
    private fun components(text: String): List<String> = text.lines().map { it.trim() }
        .filter { it.contains('/') && !it.contains(' ') && !it.contains('=') }
        .map { c ->
            val pkg = c.substringBefore('/')
            val cls = c.substringAfter('/')
            "$pkg/" + if (cls.startsWith(".")) pkg + cls else cls
        }

    private fun source(context: Context, installer: String?): String = when (installer) {
        "com.android.vending" -> context.getString(R.string.source_play_store)
        "com.google.android.packageinstaller", "com.android.packageinstaller" -> context.getString(R.string.source_apk)
        null, "null", "com.android.shell" -> context.getString(R.string.source_adb)
        else -> installer
    }

    /** The shell command, with every value quoted for the TV's shell. Stremio: its link to the stream list. */
    fun command(t: Title, component: String, stremio: Boolean = false): String = buildString {
        append("am start -n ").append(q(component)).append(" -f 0x14000000")
        if (stremio) {
            append(" -a android.intent.action.VIEW -d ").append(q(t.stremioLink(streams = true)))
            return@buildString
        }
        append(" --es contentId ").append(q(t.imdbId))
        append(" --es contentType ").append(if (t.series) "series" else "movie")
        append(" --es videoId ").append(q(t.videoId))
        append(" --es launchMode stream")
        append(" --es name ").append(q(t.name))
        if (t.series) append(" --ei season ${t.season} --ei episode ${t.episode}")
    }

    private fun q(s: String) = "'" + s.replace("'", "'\\''") + "'"

    /**
     * Off the main thread. Opens the title in `component` (null = the first app found). Returns the TV's answer;
     * throws when the TV can't be reached, has no Nuvio or Stremio app, or refuses.
     */
    suspend fun open(context: Context, host: String, t: Title, component: String?): String =
        if (Demo.on) { delay(600); "" } else withTv(context, host) { tv ->
            val apps = detect(context, tv)
            val target = apps.firstOrNull { it.component == component } ?: apps.firstOrNull()
                ?: error(context.getString(R.string.tv_no_nuvio_app))
            val r = tv.shell(command(t, target.component, target.stremio))
            val out = r.allOutput.trim()
            if (r.exitCode != 0 || out.contains("Error")) error(out.ifEmpty { context.getString(R.string.tv_said_no, r.exitCode) })
            out
        }
}
