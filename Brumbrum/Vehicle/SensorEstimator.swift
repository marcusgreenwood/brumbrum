import Foundation
import CoreMotion
import CoreLocation
import simd

/// Mount orientation, stored until the mount moves.
struct MountCalibration: Codable {
    var gravity: SIMD3<Double>     // unit vector, device frame, captured at rest
    var forward: SIMD3<Double>?    // unit vector ⟂ gravity, device frame; nil until resolved
    var lateral: SIMD3<Double>? { forward.map { simd_normalize(simd_cross(gravity, $0)) } }
}

/// Second-order Butterworth low-pass for 100 Hz control-rate signals.
struct LowPass2 {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(cutoff: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        b0 = (1 - cos(w0)) / 2 / a0; b1 = (1 - cos(w0)) / a0; b2 = b0
        a1 = -2 * cos(w0) / a0; a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Produces one `VehicleState` at 100 Hz from CoreMotion and CoreLocation.
///
/// Longitudinal acceleration is the phone's acceleration projected on the
/// calibrated forward axis and low-passed at 5 Hz. Speed is a 1-D Kalman filter
/// that integrates that acceleration and corrects on each GPS fix with a gain
/// from `speedAccuracy`.
final class SensorEstimator: NSObject, CLLocationManagerDelegate {
    enum CalibrationPhase: Equatable { case idle, orientation(progress: Double), forward(progress: Double), done, failed(String) }

    struct Diagnostics {
        var gpsSpeed: Double = -1
        var gpsAccuracy: Double = -1
        var gradientDeg: Double = 0
        var mountMoved = false
        var calibrated = false
        var forwardResolved = false
        var motionAvailable = false
        var phase: CalibrationPhase = .idle
    }

    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        q.name = "brumbrum.motion"
        return q
    }()
    private let lock = NSLock()

    // Shared (lock-protected)
    private var latest = VehicleState()
    private var diag = Diagnostics()
    var gradientCompensation = false

    // Motion-queue state
    private(set) var calibration: MountCalibration?
    private var lowPass = LowPass2(cutoff: 5, sampleRate: 100)
    private var speed = 0.0
    private var speedVar = 4.0
    private var lastAccel = 0.0
    private var jerk = 0.0
    private var lastFixTime: Date?
    private var lastFixSpeed: Double?
    private var gpsAccel = 0.0
    private var imuAccelSlow = 0.0
    private var slopeAccel = 0.0         // g·sin θ estimate
    private var gravitySlow = SIMD3<Double>(0, 0, -1)
    private var tiltedSince: TimeInterval?

    // Calibration collection
    private var phase: CalibrationPhase = .idle
    private var orientationSamples: [SIMD3<Double>] = []
    private var orientationStart: TimeInterval = 0
    private var forwardAccum = SIMD3<Double>(0, 0, 0)
    private var forwardWeight = 0.0

    static let calibrationKey = "mountCalibration"

    override init() {
        super.init()
        location.delegate = self
        location.activityType = .automotiveNavigation
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let cal = try? JSONDecoder().decode(MountCalibration.self, from: data) {
            calibration = cal
            gravitySlow = cal.gravity
        }
    }

    var isMotionAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            self.process(m)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
    }

    func current() -> (VehicleState, Diagnostics) {
        lock.lock(); defer { lock.unlock() }
        return (latest, diag)
    }

    // MARK: Calibration wizard hooks

    func beginOrientationCalibration() {
        queue.addOperation { [self] in
            orientationSamples.removeAll()
            orientationStart = ProcessInfo.processInfo.systemUptime
            phase = .orientation(progress: 0)
        }
    }

    func beginForwardCalibration() {
        queue.addOperation { [self] in
            guard calibration != nil else { phase = .failed("Capture orientation first"); return }
            forwardAccum = .zero
            forwardWeight = 0
            phase = .forward(progress: 0)
        }
    }

    func cancelCalibration() {
        queue.addOperation { [self] in phase = .idle }
    }

    func resetCalibration() {
        queue.addOperation { [self] in
            calibration = nil
            UserDefaults.standard.removeObject(forKey: Self.calibrationKey)
            phase = .idle
        }
    }

    private func saveCalibration() {
        if let cal = calibration, let data = try? JSONEncoder().encode(cal) {
            UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        }
    }

    // MARK: Motion queue

    private func process(_ m: CMDeviceMotion) {
        let g = SIMD3(m.gravity.x, m.gravity.y, m.gravity.z)
        let ua = SIMD3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z) * 9.81
        let dt = 0.01
        gravitySlow = simd_normalize(gravitySlow + (simd_normalize(g) - gravitySlow) * 0.02)

        // Calibration step 1: hold still for three seconds.
        if case .orientation = phase {
            if simd_length(ua) > 0.6 { orientationSamples.removeAll(); orientationStart = m.timestamp }
            orientationSamples.append(simd_normalize(g))
            let progress = min((m.timestamp - orientationStart) / 3, 1)
            phase = .orientation(progress: progress)
            if progress >= 1 {
                let mean = simd_normalize(orientationSamples.reduce(.zero, +))
                calibration = MountCalibration(gravity: mean, forward: calibration?.forward)
                // A remount invalidates the forward axis unless gravity barely moved.
                if let f = calibration?.forward, abs(simd_dot(f, mean)) > 0.1 { calibration?.forward = nil }
                gravitySlow = mean
                saveCalibration()
                phase = .done
            }
        }

        guard var cal = calibration else {
            publish(VehicleState(speed: speed, accel: 0, jerk: 0, confidence: 0), mountMoved: false)
            return
        }

        // Horizontal component of the phone's acceleration in the car's plane.
        let horizontal = ua - cal.gravity * simd_dot(ua, cal.gravity)

        // Calibration step 2: resolve which way is forward from one firm acceleration,
        // signed by the GPS speed derivative so braking samples count too.
        if case .forward = phase {
            if simd_length(horizontal) > 1.0, abs(gpsAccel) > 0.7 {
                forwardAccum += horizontal * (gpsAccel > 0 ? 1 : -1)
                forwardWeight += dt
            }
            let progress = min(forwardWeight / 1.5, 1)
            phase = .forward(progress: progress)
            if progress >= 1 {
                cal.forward = simd_normalize(forwardAccum - cal.gravity * simd_dot(forwardAccum, cal.gravity))
                calibration = cal
                saveCalibration()
                phase = .done
            }
        }

        // Mount knocked? A slope only tilts gravity about the lateral axis, so a
        // persistent lateral tilt, or a large total step, means the phone moved.
        var mountMoved = false
        let totalTilt = acos(min(max(simd_dot(gravitySlow, cal.gravity), -1), 1)) * 180 / .pi
        var lateralTilt = 0.0
        if let lat = cal.lateral { lateralTilt = abs(asin(min(max(simd_dot(gravitySlow, lat), -1), 1))) * 180 / .pi }
        if totalTilt > 15 || lateralTilt > 5 {
            if tiltedSince == nil { tiltedSince = m.timestamp }
            if m.timestamp - (tiltedSince ?? m.timestamp) > 1.5 { mountMoved = true }
        } else {
            tiltedSince = nil
        }

        guard let forward = cal.forward else {
            publish(VehicleState(speed: speed, accel: 0, jerk: 0, confidence: 0.1), mountMoved: mountMoved)
            return
        }

        // Proper acceleration along the car's axis: user acceleration plus whatever
        // part of gravity has rotated onto the forward axis (g·sin θ on a slope).
        let rawLong = simd_dot(ua, forward) + simd_dot(g * 9.81, forward) * -1
        var aLong = lowPass.process(rawLong)

        // Gradient: the IMU disagrees with the GPS speed derivative by g·sin θ.
        imuAccelSlow += (aLong - imuAccelSlow) * 0.005
        slopeAccel += ((imuAccelSlow - gpsAccel) - slopeAccel) * 0.002
        if gradientCompensation { aLong -= slopeAccel }

        // Kalman predict
        speed = max(speed + aLong * dt, 0)
        speedVar += 0.3 * dt
        let newJerk = (aLong - lastAccel) / dt
        jerk += (newJerk - jerk) * 0.1
        lastAccel = aLong

        let gpsAge = lastFixTime.map { Date().timeIntervalSince($0) } ?? 99
        var confidence = 1.0
        if gpsAge > 3 { confidence -= min((gpsAge - 3) / 10, 0.6) }
        confidence -= min(speedVar / 10, 0.3)
        if mountMoved { confidence = 0 }
        publish(VehicleState(speed: speed, accel: aLong, jerk: jerk, confidence: max(confidence, 0)), mountMoved: mountMoved)
    }

    private func publish(_ s: VehicleState, mountMoved: Bool) {
        lock.lock()
        latest = s
        diag.mountMoved = mountMoved
        diag.calibrated = calibration != nil
        diag.forwardResolved = calibration?.forward != nil
        diag.gradientDeg = asin(min(max(slopeAccel / 9.81, -1), 1)) * 180 / .pi
        diag.motionAvailable = true
        diag.phase = phase
        lock.unlock()
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.speed >= 0 else { return }
        let z = loc.speed
        let acc = loc.speedAccuracy > 0 ? loc.speedAccuracy : 1.5
        let time = loc.timestamp
        queue.addOperation { [self] in
            if let lt = lastFixTime, let ls = lastFixSpeed {
                let dt = time.timeIntervalSince(lt)
                if dt > 0.2 { gpsAccel += ((z - ls) / dt - gpsAccel) * 0.5 }
            }
            lastFixTime = time
            lastFixSpeed = z
            // Kalman correct
            let r = max(acc, 0.2) * max(acc, 0.2)
            let k = speedVar / (speedVar + r)
            speed = max(speed + k * (z - speed), 0)
            speedVar *= (1 - k)
            lock.lock()
            diag.gpsSpeed = z
            diag.gpsAccuracy = acc
            lock.unlock()
        }
    }
}
