package dev.skiff

import org.junit.Assert.assertEquals
import org.junit.Test

class MotionTest {
    @Test fun takesWholeCountsAndKeepsTheFractions() {
        val m = Motion()
        m.move(1.6f, -0.7f)
        m.turn(0.5f)
        m.tilt(-0.8f)
        assertEquals(Counts(1, 0, 0, 0), m.take())
        m.move(0.5f, -0.4f)
        m.turn(0.6f)
        m.tilt(-0.3f)
        // 0.6 + 0.5, -0.7 - 0.4, 0.5 + 0.6 and -0.8 - 0.3 make whole counts now.
        assertEquals(Counts(1, -1, 1, -1), m.take())
        assertEquals(Counts(0, 0, 0, 0), m.take())
    }
}
