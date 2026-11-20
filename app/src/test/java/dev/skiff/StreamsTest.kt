package dev.skiff

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamsTest {
    @Test fun knowsAStreamByItsEnding() {
        assertEquals(Streams.VIDEO, Streams.byLink("https://cdn.example.com/live/index.m3u8?token=abc"))
        assertEquals(Streams.VIDEO, Streams.byLink("http://192.168.1.20:8080/Movies/Big.Buck.Bunny.MKV"))
        assertEquals(Streams.VIDEO, Streams.byLink("https://example.com/dash/manifest.mpd"))
        assertEquals(Streams.AUDIO, Streams.byLink("https://radio.example.com/stream.mp3"))
    }

    @Test fun knowsAStreamByItsScheme() {
        assertEquals(Streams.VIDEO, Streams.byLink("rtsp://192.168.1.5:554/cam1"))
        assertEquals(Streams.VIDEO, Streams.byLink("rtmp://live.example.com/app/key"))
    }

    @Test fun aPageIsNotAStream() {
        assertNull(Streams.byLink("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertNull(Streams.byLink("https://www.hotstar.com/in/movies/maa-inti-bangaaram/1271716364"))
        assertNull(Streams.byLink("https://example.com/video.mp4.html"))
        assertNull(Streams.byLink("hotstar://in/movies/1"))
        assertNull(Streams.byLink("not a link"))
    }

    @Test fun knowsAStreamByWhatItsServerSays() {
        assertEquals(Streams.VIDEO, Streams.byContentType("video/mp4"))
        assertEquals(Streams.VIDEO, Streams.byContentType("application/vnd.apple.mpegurl; charset=utf-8"))
        assertEquals(Streams.VIDEO, Streams.byContentType("audio/mpegurl"))
        assertEquals(Streams.VIDEO, Streams.byContentType("application/dash+xml"))
        assertEquals(Streams.AUDIO, Streams.byContentType("audio/aac"))
        assertNull(Streams.byContentType("text/html; charset=utf-8"))
        assertNull(Streams.byContentType(null))
    }

    @Test fun namesAStreamByItsFile() {
        assertEquals("Big Buck Bunny", Streams.name("http://host/media/big_buck_bunny.mp4"))
        assertEquals("Sports 1", Streams.name("https://cdn.example.com/sports-1/index.m3u8"))
        assertEquals("cdn.example.com", Streams.name("https://www.cdn.example.com/index.m3u8"))
    }

    @Test fun putsVlcFirst() {
        val apps = listOf("com.brouken.player", "com.example.other", "org.videolan.vlc")
        assertEquals(listOf("org.videolan.vlc", "com.brouken.player", "com.example.other"), Streams.preferred(apps) { it })
    }

    @Test fun opensAStreamToldItsAVideo() {
        assertEquals(
            "am start -a android.intent.action.VIEW -d 'https://x.com/a.m3u8' -t 'video/*' -n 'org.videolan.vlc/org.videolan.vlc.StartActivity' -f 0x10008000",
            TvLink.linkCommand("https://x.com/a.m3u8", "org.videolan.vlc/org.videolan.vlc.StartActivity", 0x10008000, Streams.VIDEO),
        )
        assertEquals(
            "am start -a android.intent.action.VIEW -d 'https://www.youtube.com/watch?v=1' -n 'a/b' -f 0x10008000",
            TvLink.linkCommand("https://www.youtube.com/watch?v=1", "a/b", 0x10008000, null),
        )
    }
}
