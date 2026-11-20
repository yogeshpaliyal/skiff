package dev.skiff

import org.junit.Assert.assertEquals
import org.junit.Test

class NuvioCommandTest {
    private val movie = Title("tt0120737", "The Fellowship of the Ring", series = false)

    @Test fun startsNuvioAsItsIconDoesThenSendsTheTitleToThatScreen() {
        val launcher = "com.nuvio.tv/com.nuvio.tv.launcher.AppIconDefault"
        assertEquals(
            "am start -W -n '$launcher' -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 > /dev/null; " +
                "am start -n '$launcher' -f 0x34000000 --es contentId 'tt0120737' --es contentType movie " +
                "--es videoId 'tt0120737' --es launchMode stream --es name 'The Fellowship of the Ring'",
            TvLink.command(movie, "com.nuvio.tv/com.nuvio.tv.MainActivity", launcher = launcher),
        )
    }

    @Test fun withoutALauncherScreenOpensMainActivityAsBefore() {
        assertEquals(
            "am start -n 'com.nuvio.tv/com.nuvio.tv.MainActivity' -f 0x14000000 --es contentId 'tt0120737' " +
                "--es contentType movie --es videoId 'tt0120737' --es launchMode stream --es name 'The Fellowship of the Ring'",
            TvLink.command(movie, "com.nuvio.tv/com.nuvio.tv.MainActivity"),
        )
    }
}
