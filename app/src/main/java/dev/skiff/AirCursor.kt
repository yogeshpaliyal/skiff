package dev.skiff

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.sqrt

/** What one report sends: the pointer's move, the wheel's turn (up is positive) and its tilt (right is positive). */
data class Counts(val dx: Int, val dy: Int, val wheel: Int, val pan: Int) {
    val none: Boolean get() = dx == 0 && dy == 0 && wheel == 0 && pan == 0
}

/**
 * The pointer's moves (in a mouse's counts) and wheel turns and tilts, gathered as the gyroscope and the finger make them, and
 * taken whole by the loop that sends them: one report at a time, so the TV never falls behind the phone. On the main
 * thread only.
 */
class Motion {
    private var x = 0f
    private var y = 0f
    private var wheel = 0f
    private var pan = 0f

    fun move(dx: Float, dy: Float) { x += dx; y += dy }
    fun turn(n: Float) { wheel += n }
    fun tilt(n: Float) { pan += n }

    /** The whole counts gathered so far (the fractions wait for the next take). */
    fun take(): Counts {
        val t = Counts(x.toInt(), y.toInt(), wheel.toInt(), pan.toInt())
        x -= t.dx; y -= t.dy; wheel -= t.wheel; pan -= t.pan
        return t
    }

    fun clear() { x = 0f; y = 0f; wheel = 0f; pan = 0f }
}

object AirCursor {
    /** Counts per radian the phone turns: about 30° across a 1080p screen. */
    private const val GAIN = 1_800f
    /** Turning slower than this (rad/s) is the hand's tremor and the gyroscope's drift: the pointer stays put. */
    private const val STILL = 0.03f

    fun available(context: Context) =
        context.getSystemService(SensorManager::class.java)?.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null

    /**
     * Turning the phone moves the pointer, the phone held like a remote: left and right about the room's vertical
     * (gravity says which way that is in the phone, however it's tilted), up and down about the phone's side-to-side
     * axis. Until gravity is known (or without its sensor), the phone is taken as lying flat.
     */
    fun listener(onMove: (Float, Float) -> Unit) = object : SensorEventListener {
        private val up = floatArrayOf(0f, 0f, 1f)
        private var last = 0L

        override fun onSensorChanged(e: SensorEvent) {
            when (e.sensor.type) {
                Sensor.TYPE_GRAVITY -> {
                    val n = sqrt(e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2])
                    if (n > 1f) for (i in 0..2) up[i] = e.values[i] / n
                }
                Sensor.TYPE_GYROSCOPE -> {
                    val dt = if (last == 0L) 0f else ((e.timestamp - last) / 1e9f).coerceAtMost(0.1f)
                    last = e.timestamp
                    val (wx, wy, wz) = Triple(e.values[0], e.values[1], e.values[2])
                    // Yaw: about "up". Pitch: about the phone's x axis, made level (x minus its part along "up").
                    val yaw = wx * up[0] + wy * up[1] + wz * up[2]
                    var (rx, ry, rz) = Triple(1f - up[0] * up[0], -up[0] * up[1], -up[0] * up[2])
                    val rn = sqrt(rx * rx + ry * ry + rz * rz)
                    if (rn < 0.3f) { rx = 1f; ry = 0f; rz = 0f } else { rx /= rn; ry /= rn; rz /= rn }
                    val pitch = wx * rx + wy * ry + wz * rz
                    // Turning left (positive yaw) moves it left; tilting the top up (positive pitch), up.
                    onMove(
                        if (abs(yaw) < STILL) 0f else -yaw * dt * GAIN,
                        if (abs(pitch) < STILL) 0f else -pitch * dt * GAIN,
                    )
                }
            }
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }
}

/** Air cursor: while `on`, the phone's turns move the pointer. */
@Composable
fun AirMotion(on: Boolean, onMove: (Float, Float) -> Unit) {
    val context = LocalContext.current
    val move by rememberUpdatedState(onMove)
    DisposableEffect(on) {
        val sensors = context.getSystemService(SensorManager::class.java)
        val gyro = sensors?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        if (!on || sensors == null || gyro == null) return@DisposableEffect onDispose {}
        val listener = AirCursor.listener { dx, dy -> move(dx, dy) }
        sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)?.let { sensors.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME) }
        sensors.registerListener(listener, gyro, SensorManager.SENSOR_DELAY_GAME)
        onDispose { sensors.unregisterListener(listener) }
    }
}

/**
 * The touchpad, in the D-pad's place: drag to move the pointer, tap to click; the strip at its right edge scrolls up
 * and down, the one along its bottom left and right (drag down to see what's above, right to see what's to the left,
 * as on a touch screen).
 */
@Composable
fun Touchpad(
    enabled: Boolean,
    air: Boolean,
    onMove: (Float, Float) -> Unit,
    onWheel: (Float) -> Unit,
    onPan: (Float) -> Unit,
    onClick: () -> Unit,
) {
    val density = LocalDensity.current
    val move by rememberUpdatedState(onMove)
    val wheel by rememberUpdatedState(onWheel)
    val pan by rememberUpdatedState(onPan)
    val click by rememberUpdatedState(onClick)
    // Counts per dp the finger moves; a wheel step per 24 dp.
    val perPx = 2.5f / density.density
    val stepPx = with(density) { 24.dp.toPx() }
    Surface(
        shape = RoundedCornerShape(56.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 2.dp,
        modifier = Modifier.fillMaxWidth().widthIn(max = 340.dp).aspectRatio(1f),
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.weight(1f).fillMaxWidth()) {
                Box(
                    Modifier.weight(1f).fillMaxHeight()
                        .then(
                            if (!enabled) Modifier else Modifier
                                .pointerInput(Unit) { detectTapGestures(onTap = { click() }) }
                                .pointerInput(Unit) {
                                    detectDragGestures { change, drag ->
                                        change.consume()
                                        move(drag.x * perPx, drag.y * perPx)
                                    }
                                },
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(AppIcons.Mouse, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            if (air) "Point the phone at the TV and turn it to move the cursor. Drag here too; tap to click."
                            else "Drag to move the cursor; tap to click.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
                // The scroll strip.
                Surface(
                    shape = RoundedCornerShape(28.dp),
                    color = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.width(56.dp).fillMaxHeight().padding(vertical = 18.dp).padding(end = 10.dp)
                        .then(
                            if (!enabled) Modifier else Modifier.pointerInput(Unit) {
                                detectVerticalDragGestures { change, dy ->
                                    change.consume()
                                    wheel(dy / stepPx)
                                }
                            },
                        ),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text("Scroll", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            // The side-scroll strip, for rows that go left and right. It stops short of the scroll strip's column.
            Surface(
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                modifier = Modifier.fillMaxWidth().height(56.dp).padding(start = 36.dp, end = 66.dp).padding(bottom = 10.dp)
                    .then(
                        if (!enabled) Modifier else Modifier.pointerInput(Unit) {
                            detectHorizontalDragGestures { change, dx ->
                                change.consume()
                                pan(-dx / stepPx)
                            }
                        },
                    ),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text("Scroll sideways", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
