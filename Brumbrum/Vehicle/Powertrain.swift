import Foundation

struct VehicleState {
    var speed: Double = 0       // m/s
    var accel: Double = 0       // longitudinal, m/s²
    var jerk: Double = 0        // m/s³
    var confidence: Double = 0  // 0…1
}

/// Available acceleration as a function of speed. Near-flat at low speed and
/// falling off as power becomes the limit; refined by a running maximum per
/// speed bucket as the driver drives.
struct AMaxCurve: Codable {
    static let bucketWidth = 2.0
    static let bucketCount = 40

    var buckets: [Double]

    static func defaultValue(at v: Double) -> Double {
        // ~9 m/s² traction-limited, then roughly constant power (≈200 W/kg).
        min(9.0, 200 / max(v, 1)) + 0.4
    }

    static var seeded: AMaxCurve {
        AMaxCurve(buckets: (0..<bucketCount).map { defaultValue(at: (Double($0) + 0.5) * bucketWidth) * 0.6 })
    }

    /// The unlearned physical estimate; used by simulated drives.
    static var physical: AMaxCurve {
        AMaxCurve(buckets: (0..<bucketCount).map { defaultValue(at: (Double($0) + 0.5) * bucketWidth) })
    }

    func value(at v: Double) -> Double {
        let x = max(v / Self.bucketWidth - 0.5, 0)
        let i = min(Int(x), Self.bucketCount - 2)
        let f = min(x - Double(i), 1)
        return max(buckets[i] * (1 - f) + buckets[i + 1] * f, 1.0)
    }

    mutating func observe(speed v: Double, accel a: Double) {
        guard a > 0.5, a < 14, v >= 0 else { return }
        let i = min(Int(v / Self.bucketWidth), Self.bucketCount - 1)
        if a > buckets[i] { buckets[i] = a }
    }
}

struct PowertrainOutput {
    var rpm: Double
    var load: Double
    var gear: Int            // 1-based for display; 0 for direct drive
    var shiftCut: Double
    var limiter: Bool
    var shifting: Bool
}

/// The car has no rpm, so this invents one: gears, launch slip, creep,
/// shift events, idle wander and the limiter.
final class Powertrain {
    private(set) var def: EngineDefinition
    private var gear = 0
    private var rpm: Double
    private var shiftT = -1.0
    private var shiftFrom = 0.0
    private var shiftUp = true
    private var sinceShift = 10.0
    private var wanderT = 0.0
    private var wanderWalk = 0.0
    private var lastLoad = 0.0
    private var boostProxy = 0.0
    private(set) var popCounter: UInt32 = 0
    private(set) var blowoffCounter: UInt32 = 0
    private var rng = SystemRandomNumberGenerator()

    let wheelRadius = 0.36

    init(def: EngineDefinition) {
        self.def = def
        rpm = def.range.idleRpm
    }

    func setEngine(_ d: EngineDefinition, speed: Double) {
        def = d
        gear = bestGear(for: speed)
        shiftT = -1
        sinceShift = 10
        rpm = max(d.range.idleRpm, d.drivetrain.isDirect ? d.range.idleRpm : gearedRpm(speed, gear))
    }

    private func gearedRpm(_ v: Double, _ g: Int) -> Double {
        let ratios = def.drivetrain.gearRatios
        guard !ratios.isEmpty else { return def.range.idleRpm }
        let wheelRpm = v / (2 * .pi * wheelRadius) * 60
        return wheelRpm * ratios[min(max(g, 0), ratios.count - 1)] * def.drivetrain.finalDrive
    }

    private func bestGear(for v: Double) -> Int {
        let ratios = def.drivetrain.gearRatios
        guard !ratios.isEmpty else { return 0 }
        let mid = (def.drivetrain.upshiftRpm + def.drivetrain.downshiftRpm) / 2
        var g = 0
        while g < ratios.count - 1 && gearedRpm(v, g) > mid { g += 1 }
        return g
    }

    private func random(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }

    func update(state: VehicleState, load rawLoad: Double, dt: Double) -> PowertrainOutput {
        let r = def.range
        let dtrain = def.drivetrain
        let idle = r.idleRpm
        let red = r.redlineRpm
        let v = max(state.speed, 0)
        var load = min(max(rawLoad, -1), 1)
        let lp = max(load, 0)
        sinceShift += dt

        // Idle that is never perfectly steady.
        wanderT += dt
        wanderWalk += (random(-1, 1) * 2.0 - wanderWalk * 0.8) * dt
        let wander = r.idleWanderRpm * (0.55 * sin(wanderT * 2.1) + 0.3 * sin(wanderT * 5.3 + 1.0) + 0.6 * wanderWalk)
        let atRest = v < 0.3 && abs(state.accel) < 0.3

        // Turbo blow-off request: sharp lift while boost (approximated by recent load) is high.
        boostProxy += (lp - boostProxy) * min(dt * 2.0, 1)
        if def.turbo != nil && boostProxy > 0.45 && lastLoad > 0.15 && load < 0.05 {
            blowoffCounter &+= 1
            boostProxy = 0
        }
        defer { lastLoad = load }

        if dtrain.isDirect {
            // Direct drive: pitch tracks speed continuously; no shifts.
            let top = (dtrain.topSpeedKph ?? 250) / 3.6
            var target = idle + (red - idle) * min(v / top, 1.05)
            if atRest { target = idle + wander }
            let limiter = target >= red
            target = min(target, red)
            rpm += (target - rpm) * min(dt * 30, 1)
            return PowertrainOutput(rpm: rpm, load: load, gear: 0, shiftCut: 0, limiter: limiter, shifting: false)
        }

        let ratios = dtrain.gearRatios
        let up = dtrain.upshiftRpm
        let down = dtrain.downshiftRpm
        let aggressive = (def.exhaust?.overrun?.crackleDensity ?? 0) >= 0.25

        // Shift decisions, with hysteresis: hold for a moment after each shift.
        if shiftT < 0 {
            let current = gearedRpm(v, gear)
            let upThreshold = down + (up - down) * (0.4 + 0.6 * lp)   // gentle driving shifts earlier
            if sinceShift > 0.7, gear < ratios.count - 1, current > upThreshold,
               gearedRpm(v, gear + 1) > down * 1.1 {
                beginShift(up: true)
                if aggressive && lp > 0.5 { popCounter &+= 1 }
            } else if sinceShift > 0.5, gear > 0, current < down, !atRest || v > 1 {
                beginShift(up: false)
            } else if sinceShift > 0.4, gear > 0, load > 0.75, current < up * 0.55,
                      gearedRpm(v, gear - 1) < up * 0.9 {
                beginShift(up: false)                     // kickdown
            } else if atRest && gear > 0 {
                gear = 0
            }
        }

        // Launch slip ahead of road speed, and creep (clutch slipping) below first-gear idle.
        let slip = dtrain.launchSlip * lp * (red - idle) * 0.45 * exp(-v / 7)
        var desired = max(gearedRpm(v, gear), idle + slip)
        if atRest {
            desired = idle + wander + slip
        } else if desired < idle + 5 {
            desired = idle + wander * 0.5
        }

        var shiftCut = 0.0
        var target = desired
        if shiftT >= 0 {
            shiftT += dt / max(dtrain.shiftMs / 1000, 0.05)
            let t = min(shiftT, 1)
            let k = 1 - pow(1 - min(t / 0.6, 1), 3)
            target = shiftFrom + (desired - shiftFrom) * k
            if !shiftUp && aggressive { target += 350 * sin(.pi * t) }   // rev-match blip
            load *= t < 0.45 ? 0.05 : 0.05 + 0.95 * (t - 0.45) / 0.55
            shiftCut = shiftUp ? (t < 0.15 ? 0.9 : max(0, 0.9 - (t - 0.15) * 3)) : 0
            if shiftT >= 1 { shiftT = -1 }
        }

        let limiter = target >= red - 1
        target = min(target, red)
        let follow = shiftT >= 0 ? 60.0 : 25.0
        rpm += (target - rpm) * min(dt * follow, 1)
        return PowertrainOutput(rpm: rpm, load: load, gear: gear + 1, shiftCut: shiftCut,
                                limiter: limiter, shifting: shiftT >= 0)
    }

    private func beginShift(up: Bool) {
        shiftFrom = rpm
        shiftUp = up
        gear += up ? 1 : -1
        shiftT = 0
        sinceShift = 0
    }
}
