import AVFoundation
import CoreMotion
import Foundation
import MediaPlayer
import UIKit

/**
 * The pointer's moves (in a mouse's counts) and wheel turns, gathered as the gyroscope and the finger make them, and
 * taken whole by the loop that sends them: one report at a time, so the TV never falls behind the phone. Main thread
 * only. (AirCursor.kt: Motion)
 */
final class Motion {
    private var x: Float = 0
    private var y: Float = 0
    private var wheel: Float = 0

    func move(_ dx: Float, _ dy: Float) { x += dx; y += dy }
    func turn(_ n: Float) { wheel += n }

    /** The whole counts gathered so far (the fractions wait for the next take). */
    func take() -> (Int, Int, Int) {
        let t = (Int(x), Int(y), Int(wheel))
        x -= Float(t.0); y -= Float(t.1); wheel -= Float(t.2)
        return t
    }

    func clear() { x = 0; y = 0; wheel = 0 }
}

/**
 * Turning the phone moves the pointer, the phone held like a remote: left and right about the room's vertical (gravity
 * says which way that is in the phone, however it's tilted), up and down about the phone's side-to-side axis.
 * (AirCursor.kt)
 */
final class AirCursor {
    /** Counts per radian the phone turns: about 30° across a 1080p screen. */
    static let gain: Float = 1_800
    /** Turning slower than this (rad/s) is the hand's tremor and the gyroscope's drift: the pointer stays put. */
    static let still: Float = 0.03

    private let manager = CMMotionManager()
    private var last: TimeInterval = 0

    static var available: Bool { CMMotionManager().isDeviceMotionAvailable }

    /** Starts: `onMove(dx, dy)` on the main thread, about 60 times a second. */
    func start(_ onMove: @escaping (Float, Float) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        last = 0
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let dt = self.last == 0 ? 0 : Float(min(m.timestamp - self.last, 0.1))
            self.last = m.timestamp
            let (dx, dy) = AirCursor.step(
                rate: (Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z)),
                // Core Motion's gravity points down; Android's sensor (what the formula was made for) points up.
                gravity: (Float(-m.gravity.x), Float(-m.gravity.y), Float(-m.gravity.z)),
                dt: dt
            )
            if dx != 0 || dy != 0 { onMove(dx, dy) }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /** One gyroscope reading as a pointer move: yaw about "up", pitch about the phone's x axis made level. */
    static func step(rate: (Float, Float, Float), gravity: (Float, Float, Float), dt: Float) -> (Float, Float) {
        var up = (Float(0), Float(0), Float(1))
        let n = (gravity.0 * gravity.0 + gravity.1 * gravity.1 + gravity.2 * gravity.2).squareRoot()
        if n > 0.1 { up = (gravity.0 / n, gravity.1 / n, gravity.2 / n) }
        let (wx, wy, wz) = rate
        let yaw = wx * up.0 + wy * up.1 + wz * up.2
        var (rx, ry, rz) = (1 - up.0 * up.0, -up.0 * up.1, -up.0 * up.2)
        let rn = (rx * rx + ry * ry + rz * rz).squareRoot()
        if rn < 0.3 { (rx, ry, rz) = (1, 0, 0) } else { rx /= rn; ry /= rn; rz /= rn }
        let pitch = wx * rx + wy * ry + wz * rz
        // Turning left (positive yaw) moves it left; tilting the top up (positive pitch), up.
        return (abs(yaw) < still ? 0 : -yaw * dt * gain, abs(pitch) < still ? 0 : -pitch * dt * gain)
    }
}

/**
 * The phone's volume buttons turn the TV's volume while the remote is connected. iOS has no API for the buttons: the
 * system volume is watched (a press moves it), each change sent to the TV, and the volume put back to where it was so
 * the next press is seen too. (HardwareKeys.kt)
 */
@MainActor
final class VolumeButtons: NSObject {
    private var observation: NSKeyValueObservation?
    private var resetting = false
    private var level: Float = 0.5
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private var onPress: ((Int) -> Void)?

    func start(_ onPress: @escaping (Int) -> Void) {
        stop()
        self.onPress = onPress
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        level = session.outputVolume
        // Room on both sides, so either button changes it.
        if level > 0.9 || level < 0.1 { set(0.5) }
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(volumeView)
        }
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue else { return }
            Task { @MainActor in self.changed(v) }
        }
    }

    private func changed(_ v: Float) {
        if resetting {
            if abs(v - level) < 0.001 { resetting = false }
            return
        }
        if v > level { onPress?(Key.volumeUp) } else if v < level { onPress?(Key.volumeDown) }
        set(level)
    }

    private func set(_ v: Float) {
        level = v
        resetting = true
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                slider.value = v
            }
        } else {
            resetting = false
        }
    }

    func stop() {
        observation = nil
        onPress = nil
        volumeView.removeFromSuperview()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
