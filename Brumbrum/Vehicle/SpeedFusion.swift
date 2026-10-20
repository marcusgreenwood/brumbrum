import Foundation

/// Speed estimate with the motion sensors as the primary source and GPS as a
/// slow, delay-aware correction.
///
/// A two-state Kalman filter over [speed, accelerometer bias]:
/// - Every IMU sample integrates (measured acceleration − bias) into speed, so
///   speed changes are heard immediately.
/// - Each GPS fix is compared with the estimate from when the fix was really
///   measured (iOS smooths GPS speed, so it trails reality), and corrects both
///   speed and the bias. Over time GPS calibrates the accelerometer rather than
///   dragging the pitch backwards.
/// - When the car is clearly stopped, speed is pinned to zero and the bias is
///   re-learned (a zero-velocity update), which removes drift at every stop.
/// - Implausible or low-quality fixes are ignored; persistent disagreement
///   (after a tunnel, say) resets speed to GPS.
///
/// Pure Swift with no CoreMotion dependency so it can be tested offline.
struct SpeedFusion {
    struct Config {
        var accelNoise = 0.4          // m/s², white noise on the integrated acceleration
        var biasWalk = 0.004          // m/s² per √s, how fast the bias may wander
        var gpsLag = 0.8              // s, how far iOS GPS speed trails reality
        var gpsNoiseFloor = 0.3       // m/s, minimum trusted GPS speed error
        var gpsModelNoise = 0.35      // m/s, extra slack so GPS corrects slowly
        var gateSigma = 4.5           // reject fixes this many σ from the estimate
        var stillThreshold = 0.07     // m/s², acceleration wobble below which the car may be stopped
        var stillSeconds = 0.8
    }

    var config = Config()
    /// Unclamped internally so the bias can learn in both directions while stopped.
    private var v = 0.0
    private(set) var bias = 0.0
    var speed: Double { max(v, 0) }
    private(set) var stationary = false
    private(set) var lastInnovation = 0.0
    private(set) var rejectedFixes = 0

    // Covariance of [speed, bias]
    private var pvv = 4.0, pvb = 0.0, pbb = 0.05

    // Recent (time, speed) estimates for delay-aware comparison; ring buffer, 5 s at 100 Hz.
    private var histT = [Double](repeating: 0, count: 512)
    private var histV = [Double](repeating: 0, count: 512)
    private var histCount = 0
    private var histHead = 0

    // Vibration level, for stop detection
    private var aMean = 0.0
    private var aVar = 1.0
    private var stillTime = 0.0
    private var lastGPSSpeed: Double?
    private var lastGPSTime = -Double.infinity
    private var now = 0.0

    var speedStdDev: Double { pvv.squareRoot() }

    /// Feed one IMU sample: longitudinal acceleration in m/s² at time `t` (s).
    mutating func predict(acceleration a: Double, at t: Double, dt: Double) {
        now = t
        v += (a - bias) * dt

        // P = F P Fᵀ + Q with F = [[1, −dt], [0, 1]]
        pvv += -2 * dt * pvb + dt * dt * pbb + config.accelNoise * config.accelNoise * dt
        pvb += -dt * pbb
        pbb += config.biasWalk * config.biasWalk * dt

        // Stop detection from how much the acceleration wobbles.
        let k = min(dt / 0.25, 1)
        aMean += (a - aMean) * k
        aVar += ((a - aMean) * (a - aMean) - aVar) * k
        let gpsSaysStill = (lastGPSSpeed ?? 0) < 0.6 || t - lastGPSTime > 3
        if aVar.squareRoot() < config.stillThreshold && v < 2.5 && gpsSaysStill {
            stillTime += dt
        } else {
            stillTime = 0
        }
        stationary = stillTime >= config.stillSeconds
        if stationary { zeroVelocityUpdate() }

        histT[histHead] = t
        histV[histHead] = v
        histHead = (histHead + 1) % histT.count
        histCount = min(histCount + 1, histT.count)
    }

    /// Speed estimate at an earlier time, linearly interpolated from history.
    private func speed(at t: Double) -> Double? {
        guard histCount > 1 else { return nil }
        let n = histT.count
        var newer = (histHead - 1 + n) % n
        if t >= histT[newer] { return histV[newer] }
        for _ in 1..<histCount {
            let older = (newer - 1 + n) % n
            if histT[older] <= t {
                let span = histT[newer] - histT[older]
                let f = span > 0 ? (t - histT[older]) / span : 0
                return histV[older] + (histV[newer] - histV[older]) * f
            }
            newer = older
        }
        return nil   // older than the buffer
    }

    /// Feed one GPS fix. `measuredAt` is the fix timestamp on the same clock as `predict`.
    mutating func gps(speed z: Double, accuracy: Double, measuredAt t: Double) {
        lastGPSSpeed = z
        lastGPSTime = t
        let tEff = t - config.gpsLag
        guard let vThen = speed(at: tEff) else { return }
        let lag = max(now - tEff, 0)

        // State x = [v_now, b]. The estimate back then was v_now − Σ(a − b)dt, so the
        // measurement model is H = [1, lag].
        let y = z - vThen
        lastInnovation = y
        let r = max(accuracy, config.gpsNoiseFloor)
        let R = r * r + config.gpsModelNoise * config.gpsModelNoise
        let phv = pvv + lag * pvb          // (P Hᵀ)_v
        let phb = pvb + lag * pbb          // (P Hᵀ)_b
        let S = phv + lag * phb + R

        if abs(y) > config.gateSigma * S.squareRoot() {
            rejectedFixes += 1
            if rejectedFixes >= 4 {
                // GPS has disagreed for several seconds: trust it.
                shiftHistory(by: y)
                v += y
                pvv = R; pvb = 0
                rejectedFixes = 0
            }
            return
        }
        rejectedFixes = 0

        let kv = phv / S, kb = phb / S
        v += kv * y
        bias += kb * y
        shiftHistory(by: kv * y)
        let nvv = pvv - kv * phv
        let nvb = pvb - kv * phb
        let nbb = pbb - kb * phb
        pvv = max(nvv, 1e-6); pvb = nvb; pbb = max(nbb, 1e-8)
    }

    /// Zero-velocity update: the car is stopped, so speed is 0 and whatever the
    /// accelerometer reads is bias (plus slope).
    private mutating func zeroVelocityUpdate() {
        let R = 0.05 * 0.05
        let y = 0 - v
        let S = pvv + R
        let kv = pvv / S, kb = pvb / S
        v += kv * y
        bias += kb * y
        pbb -= kb * pvb
        pvb -= kv * pvb
        pvv -= kv * pvv
        pvv = max(pvv, 1e-6); pbb = max(pbb, 1e-8)
    }

    private mutating func shiftHistory(by dv: Double) {
        for i in 0..<histT.count { histV[i] += dv }
    }
}
