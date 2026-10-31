package dev.skiff

import org.junit.Assert.assertEquals
import org.junit.Test

class MetaTest {
    @Test fun keepsTheWordsAndOneSpaceBetweenThem() {
        assertEquals("breaking bad", Meta.words("breaking bad"))
        assertEquals("breaking bad", Meta.words("  breaking   bad "))
        assertEquals("breaking bad", Meta.words("breaking\tbad"))
    }

    @Test fun anyKindOfSpaceIsASpace() {
        assertEquals("breaking bad", Meta.words("breaking bad"))      // no-break space
        assertEquals("dune part two", Meta.words("dune part two"))     // thin, narrow no-break
        assertEquals("the office", Meta.words("the　office"))       // ideographic
    }

    @Test fun dropsInvisibleCharacters() {
        assertEquals("the office", Meta.words("the​ office﻿"))
    }

    @Test fun searchUrlEncodesSpacesAsPercent20() {
        assertEquals(
            "https://v3-cinemeta.strem.io/catalog/series/top/search=breaking%20bad.json",
            Meta.searchUrl("series", " breaking  bad "),
        )
        assertEquals(
            "https://v3-cinemeta.strem.io/catalog/movie/top/search=schindler%27s%20list%20%2B%201.json",
            Meta.searchUrl("movie", "schindler's list + 1"),
        )
    }
}
