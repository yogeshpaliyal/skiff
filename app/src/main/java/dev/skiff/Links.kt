package dev.skiff

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale

/**
 * Any other link (JioHotstar, YouTube, Netflix…): sent to the TV as a plain VIEW intent, to whichever TV app opens it.
 * Some apps open their website's links badly on TV; those are turned into the app's own link first.
 */
object Links {
    data class Page(val title: String, val image: String? = null, val by: String? = null)

    private val URL_IN_TEXT = Regex("""(https?://\S+|[a-z][a-z0-9+.-]*://\S+)""", RegexOption.IGNORE_CASE)

    /** The first link in shared text. */
    fun linkIn(text: String): String? = URL_IN_TEXT.find(text)?.value?.trimEnd('.', ',', ')', '"', '\'')

    fun isLink(s: String) = URL_IN_TEXT.matches(s.trim())

    /** The link the TV app wants: its rule's rewrite (JioHotstar: www.hotstar.com/in/… → hotstar://in/…), or as it is. */
    fun forTv(link: String): String = Rules.forTv(link)

    /** "www.hotstar.com", or the scheme of an app link ("hotstar"). */
    fun site(link: String): String = runCatching {
        val u = Uri.parse(link)
        (u.host ?: u.scheme).orEmpty().removePrefix("www.").removePrefix("m.")
    }.getOrDefault(link)

    /** The TV app's name for its package (the rules' list); others by package. */
    fun appName(pkg: String): String = Rules.appName(pkg)

    /**
     * A name (and picture) for the link, off the main thread, from where its rule says: "oembed:<url>" (YouTube),
     * "og" (the page's Open Graph tags, when they name this page: JioHotstar's only name the site), or "slug" (the
     * title in the link itself: ".../movies/maa-inti-bangaaram/1271716364" → "Maa Inti Bangaaram"). No rule: the
     * page's tags, then the slug. Else `fallback` (the shared page's title), else the site.
     */
    suspend fun page(link: String, fallback: String?): Page = withContext(Dispatchers.IO) {
        // A stream (a video file, an .m3u8…): no page to read; named by the share, else its file.
        if (Streams.byLink(link) != null) {
            return@withContext Page(fallback?.takeIf { it.isNotBlank() } ?: Streams.name(link) ?: site(link))
        }
        val how = Rules.ruleFor(link)?.title
        val fromWeb = runCatching {
            when {
                how != null && how.startsWith("oembed:") -> oembed(how.removePrefix("oembed:"), link)
                how == "slug" -> null
                link.startsWith("http") -> openGraph(link)
                else -> null
            }
        }.getOrNull()
        fromWeb?.takeIf { it.title.isNotBlank() }
            ?: fromSlug(link)?.let { Page(it) }
            ?: Page(fallback?.takeIf { it.isNotBlank() } ?: site(link))
    }

    /** An oEmbed endpoint ("https://www.youtube.com/oembed?format=json&url={link}"), https only. */
    private fun oembed(endpoint: String, link: String): Page? {
        val url = endpoint.replace("{link}", URLEncoder.encode(link, "UTF-8"))
        if (!url.startsWith("https://")) return null
        val o = JSONObject(get(url) ?: return null)
        return Page(o.optString("title"), o.optString("thumbnail_url").takeIf { it.startsWith("http") }, o.optString("author_name").takeIf { it.isNotBlank() })
    }

    private fun openGraph(link: String): Page? {
        val html = get(link, limit = 400_000) ?: return null
        fun meta(p: String) = Regex("""<meta[^>]+(?:property|name)=["']$p["'][^>]*content=["']([^"']+)""", RegexOption.IGNORE_CASE)
            .find(html)?.groupValues?.get(1)?.let(::unescape)
        val title = meta("og:title") ?: return null
        val siteName = meta("og:site_name")
        // A site-wide title ("JioHotstar - Watch TV Shows, Movies…") doesn't name the page.
        val generic = siteName != null && title.startsWith(siteName) || title.contains(" - Watch ")
        return if (generic) null else Page(title, meta("og:image")?.takeIf { it.startsWith("http") }, siteName)
    }

    /** The longest words-with-hyphens segment of the path that isn't a known section. */
    private fun fromSlug(link: String): String? {
        val skip = setOf("in", "movies", "shows", "watch", "title", "detail", "video", "videos", "series", "tv", "episode")
        val words = runCatching { Uri.parse(link).pathSegments }.getOrDefault(emptyList())
            .filter { it.lowercase(Locale.ROOT) !in skip && Regex("""[a-zA-Z]+(-[a-zA-Z0-9]+)+""").matches(it) }
            .maxByOrNull { it.length } ?: return null
        return words.split('-').joinToString(" ") { w -> w.replaceFirstChar { it.titlecase(Locale.ROOT) } }
    }

    private fun unescape(s: String) = s.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'")
        .replace("&lt;", "<").replace("&gt;", ">")

    /** A page's text (up to `limit` bytes), as a phone's browser asks for it; null when it doesn't answer 2xx. */
    internal fun get(url: String, limit: Int = 200_000): String? {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 6000
        c.readTimeout = 8000
        c.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36")
        return try {
            if (c.responseCode !in 200..299) return null
            val bytes = c.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(16_384)
                while (out.size() < limit) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                }
                out.toByteArray()
            }
            String(bytes, Charsets.UTF_8)
        } finally {
            c.disconnect()
        }
    }
}
