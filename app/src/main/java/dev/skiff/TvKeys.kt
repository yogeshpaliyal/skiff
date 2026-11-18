package dev.skiff

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A remote connection to the TV, whichever way it goes: the Google TV remote protocol (paired with a code, no
 * developer options: atv.Atv.Remote) or the TV's ADB (TvLink.Remote). Keys are Android's KeyEvent codes.
 */
interface TvKeys : AutoCloseable {
    suspend fun key(code: Int)

    /** Over the remote protocol with a field focused, replaces the field's text; otherwise types it in. */
    suspend fun text(s: String)

    /**
     * The text of the TV's focused field, as the TV tells it; null when it doesn't (ADB, or no field focused). While
     * it's known, [text] replaces the field's text, so the phone's field can mirror it as you type.
     */
    val field: StateFlow<String?> get() = NO_FIELD

    /**
     * Still connected, as far as the phone knows. False once the TV closed it: over the remote protocol it keeps one
     * remote at a time, so another phone (or Skiff Debug) connecting closes this one.
     */
    val isOpen: Boolean get() = true

    /** A mouse pointer on the TV ([mouse]): over ADB only, the remote protocol has none. */
    val hasCursor: Boolean get() = false

    /**
     * Moves the TV's mouse pointer by (dx, dy), in a mouse's counts, with `buttons` held ([BUTTON_LEFT]…: a click is
     * a report with it, then one without), the wheel turned by `wheel` (up is positive) and tilted by `pan` (right is
     * positive: rows that go sideways).
     */
    suspend fun mouse(dx: Int, dy: Int, buttons: Int = 0, wheel: Int = 0, pan: Int = 0) {}

    companion object {
        const val BUTTON_LEFT = 1
        const val BUTTON_RIGHT = 2
        private val NO_FIELD: StateFlow<String?> = MutableStateFlow(null)
    }
}
