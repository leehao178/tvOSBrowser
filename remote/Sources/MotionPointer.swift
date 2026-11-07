import CoreMotion
import Foundation

/// Turns the phone's gyroscope into yaw / pitch deltas (radians since the previous sample).
///
/// Yaw is measured around the real-world vertical axis (using gravity), so it works whether the
/// phone is held flat like a remote or upright. +yaw = turned right, +pitch = tipped up.
///
/// Jitter handling, in order:
/// 1. Adaptive low-pass filter: heavy smoothing for slow, small movements (hand tremor),
///    light smoothing for fast movements so big swings don't lag.
/// 2. Soft dead zone: rotation slower than the threshold is ignored, and movement above it
///    ramps up from zero instead of jumping.
final class MotionPointer {
    struct Settings: Equatable {
        /// Multiplier on top of the Apple TV's own sensitivity. 1 = unchanged.
        var speed: Double = 1.0
        /// Rotation slower than this (rad/s) is ignored.
        var deadZone: Double = 0.03
        /// 0 = no smoothing, 1 = maximum smoothing.
        var smoothing: Double = 0.5
    }

    var onDelta: ((_ dyaw: Double, _ dpitch: Double) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var settings: Settings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    /// While paused (e.g. a finger is on the touch pad) no movement is sent, so tapping
    /// the phone doesn't knock the cursor off its target.
    var isPaused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    private let manager = CMMotionManager()
    private let updateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "remote.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var _settings = Settings()
    private var _paused = false

    // Only touched on updateQueue.
    private var lastTimestamp: TimeInterval?
    private var filteredYaw = 0.0
    private var filteredPitch = 0.0
    private var wasPaused = false

    private let maxInterval = 0.05    // s, caps a gap between samples

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        updateQueue.addOperation { [weak self] in self?.resetFilter() }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: updateQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func resetFilter() {
        lastTimestamp = nil
        filteredYaw = 0
        filteredPitch = 0
    }

    private func handle(_ motion: CMDeviceMotion) {
        let (settings, paused) = lock.withLock { (_settings, _paused) }
        if paused {
            wasPaused = true
            return
        }
        if wasPaused {
            // Start fresh after a pause so movement made while paused doesn't leak out.
            wasPaused = false
            resetFilter()
        }

        defer { lastTimestamp = motion.timestamp }
        guard let last = lastTimestamp else { return }
        let dt = min(motion.timestamp - last, maxInterval)
        guard dt > 0 else { return }

        let rate = motion.rotationRate
        let gravity = motion.gravity
        let length = sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z)
        guard length > 0.1 else { return }

        // Rotation about the downward gravity vector: turning right (clockwise seen from above) is positive.
        let yawRate = (rate.x * gravity.x + rate.y * gravity.y + rate.z * gravity.z) / length
        // The device x axis runs across the phone's width; tipping the top up is positive.
        let pitchRate = rate.x

        // 1. Adaptive low-pass: the cutoff frequency rises with how fast the phone is turning.
        let smoothing = min(max(settings.smoothing, 0), 1)
        let minCutoff = 10.0 * pow(0.06, smoothing)   // 10 Hz (barely smoothed) … 0.6 Hz (very smooth)
        let speedBoost = 12.0 * (1.0 - 0.5 * smoothing)
        let currentSpeed = hypot(filteredYaw, filteredPitch)
        let cutoff = minCutoff + speedBoost * currentSpeed
        let alpha = 1.0 / (1.0 + 1.0 / (2.0 * Double.pi * cutoff * dt))
        filteredYaw += alpha * (yawRate - filteredYaw)
        filteredPitch += alpha * (pitchRate - filteredPitch)

        // 2. Soft dead zone on the combined rotation speed.
        let magnitude = hypot(filteredYaw, filteredPitch)
        let deadZone = max(settings.deadZone, 0)
        guard magnitude > deadZone, magnitude > 0 else { return }
        let scale = (magnitude - deadZone) / magnitude * settings.speed

        onDelta?(filteredYaw * scale * dt, filteredPitch * scale * dt)
    }
}
