package dev.skiff

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * A link to the video (or audio) itself, not a page: "https://…/live/index.m3u8", "http://…/movie.mkv",
 * "rtsp://camera/stream". The TV has no app that says it opens such a link by the link alone (only browsers do), but
 * its players (VLC, MX Player, Just Player, Kodi…) open it when told what it is: a VIEW intent with a type, "video/ *".
 *
 * Known by the link's ending or scheme; else, for a web link that names no page (no rule, no known ending), by what its
 * server says it is (a HEAD, then the first bytes of a GET: some servers answer HEAD badly).
 */
object Streams {
    private val VIDEO_ENDINGS = setOf(
        "m3u8", "m3u", "mpd", "ism", "mp4", "m4v", "mkv", "webm", "avi", "mov", "ts", "m2ts", "mts", "flv", "wmv",
        "3gp", "mpg", "mpeg", "ogv", "vob",
    )
    private val AUDIO_ENDINGS = setOf("mp3", "aac", "m4a", "flac", "ogg", "oga", "opus", "wav", "wma", "pls")
    /** Streaming schemes: never a page. */
    private val STREAM_SCHEMES = setOf("rtsp", "rtsps", "rtmp", "rtmps", "rtp", "udp", "mms", "mmsh", "srt")

    /** The type sent with the link: what the TV's players say they open. */
    const val VIDEO = "video/*"
    const val AUDIO = "audio/*"

    /** What the server said, per link: asked once (the lookup of apps, then the start). */
    private val sniffed = ConcurrentHashMap<String, String>()
    private const val NOT_MEDIA = ""

    /** The type for a link known by its ending or scheme ("video/ *", "audio/ *"), else null. No network. */
    fun byLink(link: String): String? {
        val uri = runCatching { URI(link.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
        if (scheme in STREAM_SCHEMES) return VIDEO
        if (scheme != "http" && scheme != "https") return null
        val ending = (uri.rawPath.orEmpty().substringAfterLast('/').substringAfterLast('.', "")).lowercase(Locale.ROOT)
        return when (ending) {
            in VIDEO_ENDINGS -> VIDEO
            in AUDIO_ENDINGS -> AUDIO
            else -> null
        }
    }

    /** The type for a server's Content-Type ("application/vnd.apple.mpegurl" → "video/ *"), or null for a page. */
    fun byContentType(contentType: String?): String? {
        val t = contentType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT) ?: return null
        return when {
            t.startsWith("video/") -> VIDEO
            t.startsWith("audio/") && !t.contains("mpegurl") -> AUDIO
            t.contains("mpegurl") -> VIDEO      // HLS: application/vnd.apple.mpegurl, application/x-mpegurl, audio/mpegurl
            t == "application/dash+xml" || t == "application/vnd.ms-sstr+xml" -> VIDEO
            t == "application/octet-stream" -> null     // a download of anything: not known to be a video
            else -> null
        }
    }

    /**
     * Off the main thread: the type for a link (null: a page, opened as it is). A link a rule knows (YouTube,
     * JioHotstar…) is a page; one without a known ending asks its server, once.
     */
    suspend fun type(link: String): String? {
        byLink(link)?.let { return it }
        if (!link.startsWith("http", ignoreCase = true) || Rules.ruleFor(link) != null || TitleSources.of(link) != null) return null
        sniffed[link]?.let { return it.takeIf { t -> t != NOT_MEDIA } }
        val found = withContext(Dispatchers.IO) { runCatching { ask(link) }.getOrNull() }
        sniffed[link] = found ?: NOT_MEDIA
        return found
    }

    /** The server's Content-Type for the link: a HEAD, else a GET of its first byte. */
    private fun ask(link: String): String? {
        for (method in listOf("HEAD", "GET")) {
            val c = URL(link).openConnection() as HttpURLConnection
            try {
                c.requestMethod = method
                c.instanceFollowRedirects = true
                c.connectTimeout = 4000
                c.readTimeout = 4000
                c.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36")
                if (method == "GET") c.setRequestProperty("Range", "bytes=0-0")
                if (c.responseCode in 200..299 || c.responseCode == 206) return byContentType(c.contentType)
            } finally {
                c.disconnect()
            }
        }
        return null
    }

    /** A name for a stream: its file's name ("Big Buck Bunny" from ".../big_buck_bunny.mp4"), else its site. */
    fun name(link: String): String? {
        val uri = runCatching { URI(link.trim()) }.getOrNull() ?: return null
        val file = uri.path.orEmpty().substringAfterLast('/').substringBeforeLast('.')
        // "index.m3u8", "playlist.m3u8", "master.m3u8", "manifest.mpd": the folder names it, if anything.
        val generic = file.lowercase(Locale.ROOT) in setOf("", "index", "playlist", "master", "manifest", "stream", "live", "chunklist", "mono", "video")
        val words = if (!generic) file else uri.path.orEmpty().trimEnd('/').substringBeforeLast('/').substringAfterLast('/')
        val pretty = words.replace(Regex("[._+-]+"), " ").trim()
        if (pretty.isEmpty() || pretty.length > 80) return uri.host?.removePrefix("www.")
        return pretty.split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.titlecase(Locale.ROOT) } }
    }

    /** The players to put first, in order, when the TV has them. */
    val PLAYERS = listOf(
        "org.videolan.vlc",             // VLC
        "com.mxtech.videoplayer.pro",   // MX Player Pro
        "com.mxtech.videoplayer.ad",    // MX Player
        "com.brouken.player",           // Just Player
        "org.xbmc.kodi",                // Kodi
    )

    /** Players first (VLC on top), then the rest as the TV listed them. */
    fun <T> preferred(apps: List<T>, pkg: (T) -> String): List<T> =
        apps.sortedBy { a -> PLAYERS.indexOf(pkg(a)).let { if (it < 0) PLAYERS.size else it } }
}
