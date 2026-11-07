import CoreMotion
import Foundation

/// Turns the phone's gyroscope into yaw / pitch deltas (radians since the previous sample).
///
/// Yaw is measured around the real-world vertical axis (using gravity), so it works whether the
/// phone is held flat like a remote or upright. +yaw = turned right, +pitch = tipped up.
final class MotionPointer {
    var onDelta: ((_ dyaw: Double, _ dpitch: Double) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    private let manager = CMMotionManager()
    private let updateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "remote.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var lastTimestamp: TimeInterval?

    private let deadZone = 0.015      // rad/s, ignores hand tremor
    private let maxInterval = 0.05    // s, caps a gap between samples

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lastTimestamp = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: updateQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lastTimestamp = nil
    }

    private func handle(_ motion: CMDeviceMotion) {
        defer { lastTimestamp = motion.timestamp }
        guard let last = lastTimestamp else { return }
        let dt = min(motion.timestamp - last, maxInterval)
        guard dt > 0 else { return }

        let rate = motion.rotationRate
        let gravity = motion.gravity
        let length = sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z)
        guard length > 0.1 else { return }

        // Rotation about the downward gravity vector: turning right (clockwise seen from above) is positive.
        var yawRate = (rate.x * gravity.x + rate.y * gravity.y + rate.z * gravity.z) / length
        // The device x axis runs across the phone's width; tipping the top up is positive.
        var pitchRate = rate.x

        if abs(yawRate) < deadZone { yawRate = 0 }
        if abs(pitchRate) < deadZone { pitchRate = 0 }
        if yawRate == 0 && pitchRate == 0 { return }

        onDelta?(yawRate * dt, pitchRate * dt)
    }
}
