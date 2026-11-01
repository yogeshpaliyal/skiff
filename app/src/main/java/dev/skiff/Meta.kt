package dev.skiff

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Titles found by name (search), and a title's name and type from its IMDb id, through Cinemeta (the free catalog Stremio and Nuvio use; no key).
 * An id is either a movie or a series: both are asked at once, and the one that answers wins.
 */
object Meta {
    data class Found(
        val name: String,
        val series: Boolean,
        val poster: String? = null,
        val background: String? = null,
        val year: String? = null,       // "2001", "2025–"
        val genres: List<String> = emptyList(),
        val rating: String? = null,     // IMDb, "8.9"
        val runtime: String? = null,    // "179 min"
    )

    private const val CINEMETA = "https://v3-cinemeta.strem.io/meta"
    private const val CATALOG = "https://v3-cinemeta.strem.io/catalog"

    /** A search result: an IMDb title, enough to show it and fill it in. */
    data class Hit(val imdbId: String, val name: String, val series: Boolean, val year: String?, val poster: String?)

    /**
     * The words typed, as Cinemeta should get them: every run of spaces of any kind (a keyboard's no-break or thin
     * space, a tab, two spaces in a row) one plain space, and the invisible characters some keyboards add removed.
     */
    fun words(query: String): String =
        query.replace(INVISIBLE, "").split(SPACES).filter { it.isNotEmpty() }.joinToString(" ")

    private val SPACES = Regex("""[\s\p{Z}]+""")
    private val INVISIBLE = Regex("""[\u200B-\u200D\u2060\uFEFF]""")

    /** The catalog address for a search: the words percent-encoded, a space as %20 (a "+" is a plus in a path). */
    fun searchUrl(type: String, query: String): String =
        "$CATALOG/$type/top/search=${java.net.URLEncoder.encode(words(query), "UTF-8").replace("+", "%20")}.json"

    /**
     * Off the main thread. Titles whose name matches `query`, movies and series asked at once and taken in turn
     * (the best of each first), up to `limit`. Only the words typed go to Cinemeta. When several words find nothing,
     * the last ones are let go of, one at a time and at most two (an extra word, a typo at the end). Empty on no match
     * or no internet.
     */
    suspend fun search(query: String, limit: Int = Int.MAX_VALUE): List<Hit> {
        val all = words(query).split(" ").filter { it.isNotEmpty() }
        for (n in all.size downTo maxOf(1, all.size - 2)) {
            val q = all.take(n).joinToString(" ")
            if (n < all.size && q.length < 3) break     // one short word left: too broad to stand for what was typed
            val hits = searchOnce(q, limit)
            if (hits.isNotEmpty()) return hits
        }
        return emptyList()
    }

    private suspend fun searchOnce(query: String, limit: Int): List<Hit> = coroutineScope {
        val movies = async { catalog("movie", query) }
        val series = async { catalog("series", query) }
        val m = movies.await()
        val s = series.await()
        buildList { for (i in 0 until maxOf(m.size, s.size)) { m.getOrNull(i)?.let(::add); s.getOrNull(i)?.let(::add) } }
            .distinctBy { it.imdbId }
            .take(limit)
    }

    private suspend fun catalog(type: String, query: String): List<Hit> = withContext(Dispatchers.IO) {
        runCatching {
            val c = URL(searchUrl(type, query)).openConnection() as HttpURLConnection
            c.connectTimeout = 6000
            c.readTimeout = 8000
            try {
                if (c.responseCode != 200) return@runCatching emptyList()
                val a = JSONObject(c.inputStream.bufferedReader().readText()).optJSONArray("metas") ?: return@runCatching emptyList()
                List(a.length()) { a.getJSONObject(it) }
                    .filter { Title.isImdbId(it.optString("id")) && it.optString("name").isNotBlank() }
                    .map {
                        Hit(
                            imdbId = it.optString("id"),
                            name = it.optString("name"),
                            series = type == "series",
                            year = it.optString("releaseInfo").takeIf { y -> y.isNotBlank() && y != "null" },
                            poster = it.optString("poster").takeIf { p -> p.startsWith("http") },
                        )
                    }
            } finally {
                c.disconnect()
            }
        }.getOrDefault(emptyList()).also { ensureActive() }     // typed on meanwhile: not these
    }

    /** Off the main thread; null when neither knows it (or there's no internet). */
    suspend fun lookup(imdbId: String): Found? = coroutineScope {
        val movie = async { fetch("movie", imdbId) }
        val series = async { fetch("series", imdbId) }
        movie.await()?.let { found(it, false) } ?: series.await()?.let { found(it, true) }
    }

    private fun found(m: JSONObject, series: Boolean) = Found(
        name = m.optString("name"),
        series = series,
        poster = m.optString("poster").takeIf { it.startsWith("http") },
        background = m.optString("background").takeIf { it.startsWith("http") },
        year = m.optString("releaseInfo").takeIf { it.isNotBlank() },
        genres = m.optJSONArray("genres")?.let { a -> List(a.length()) { a.optString(it) } }.orEmpty().take(3),
        rating = m.optString("imdbRating").takeIf { it.isNotBlank() },
        runtime = m.optString("runtime").takeIf { it.isNotBlank() },
    )

    /** The title's "meta" object, when this type knows the id. */
    private suspend fun fetch(type: String, id: String): JSONObject? = withContext(Dispatchers.IO) {
        runCatching {
            val c = URL("$CINEMETA/$type/$id.json").openConnection() as HttpURLConnection
            c.connectTimeout = 6000
            c.readTimeout = 8000
            c.instanceFollowRedirects = false   // the wrong type redirects (307): not this one
            try {
                if (c.responseCode != 200) return@runCatching null
                val meta = JSONObject(c.inputStream.bufferedReader().readText()).optJSONObject("meta")
                meta?.takeIf { it.optString("name").isNotBlank() }
            } finally {
                c.disconnect()
            }
        }.getOrNull()
    }
}
