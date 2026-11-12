package dev.skiff

import android.content.Context
import android.content.Intent

/**
 * Demo mode, for store screenshots (debug builds only; Settings → Demo mode): a made-up TV that's found, paired and
 * allowed, its apps, and a sample history, with nothing sent anywhere. Read once at launch: switching it restarts
 * the app.
 */
object Demo {
    const val HOST = "192.168.1.42"
    const val TV = "Living room TV"

    @Volatile var on = false
        private set

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** At launch. `fromIntent`: `--ez demo true|false` switches it first (debug builds; for scripted screenshots). */
    fun init(context: Context, fromIntent: Boolean? = null) {
        if (fromIntent != null && Telemetry.debuggable(context)) prefs(context).edit().putBoolean("demo", fromIntent).commit()
        on = Telemetry.debuggable(context) && prefs(context).getBoolean("demo", false)
        // Out of demo mode: the made-up TV isn't kept as the one picked (the real one is found again).
        val picked = context.getSharedPreferences("remote", Context.MODE_PRIVATE)
        if (!on && picked.getString("host", null)?.trim() == HOST) picked.edit().remove("host").remove("tvName").apply()
    }

    /** Switches it, and restarts the app so every screen starts over with it. */
    fun set(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean("demo", value).commit()
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        Runtime.getRuntime().exit(0)
    }

    /** The TVs "found" on the Wi-Fi: one set up, one not yet. */
    fun tvs() = listOf(TvFinder.Tv(HOST, TV, ready = true), TvFinder.Tv("192.168.1.57", "Bedroom TV", ready = false))

    fun nuvioApps() = listOf(TvLink.NuvioApp("com.nuvio.tv", "com.nuvio.tv/com.nuvio.tv.MainActivity", "1.0.0", "Play Store"))

    /** The TV's apps for a link: the one for its site first. */
    fun linkApps(link: String, type: String? = null): List<TvLink.LinkApp> {
        if (type != null) return listOf(
            TvLink.LinkApp("org.videolan.vlc", "org.videolan.vlc/org.videolan.vlc.StartActivity"),
            TvLink.LinkApp("com.brouken.player", "com.brouken.player/com.brouken.player.PlayerActivity"),
        )
        val youtube = TvLink.LinkApp("com.google.android.youtube.tv", "com.google.android.youtube.tv/com.google.android.apps.youtube.tv.activity.ShellActivity")
        val hotstar = TvLink.LinkApp("in.startv.hotstar", "in.startv.hotstar/com.hotstar.MainActivity")
        return if ("hotstar" in link) listOf(hotstar) else listOf(youtube)
    }

    /** The remote: keys and text go nowhere. */
    val keys = object : TvKeys {
        override suspend fun key(code: Int) {}
        override suspend fun text(s: String) {}
        override val hasCursor = true
        override fun close() {}
    }

    /** History and Saved for later, for the screenshots: well-known titles, posters from Cinemeta's image host. */
    fun samples(): List<Library.Entry> {
        val now = System.currentTimeMillis()
        val hour = 3_600_000L
        fun poster(id: String) = "https://images.metahub.space/poster/medium/$id/img"
        return listOf(
            Library.Entry("tt12004706", "Panchayat", series = true, season = 3, episode = 5, poster = poster("tt12004706"), year = "2020–", plays = 9, lastUsed = now - hour / 2),
            Library.Entry("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", series = false,
                poster = "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg", plays = 3, lastUsed = now - 3 * hour,
                link = "https://www.youtube.com/watch?v=aqz-KE-bpKQ", app = "YouTube"),
            Library.Entry("tt0816692", "Interstellar", series = false, poster = poster("tt0816692"), year = "2014", plays = 1, lastUsed = now - 26 * hour),
            Library.Entry("tt0903747", "Breaking Bad", series = true, season = 3, episode = 7, poster = poster("tt0903747"), year = "2008–2013", saved = true, plays = 14, lastUsed = now - 50 * hour),
            Library.Entry("tt1187043", "3 Idiots", series = false, poster = poster("tt1187043"), year = "2009", saved = true, inHistory = false, lastUsed = now - 80 * hour),
            Library.Entry("tt15239678", "Dune: Part Two", series = false, poster = poster("tt15239678"), year = "2024", saved = true, inHistory = false, lastUsed = now - 90 * hour),
        )
    }
}
