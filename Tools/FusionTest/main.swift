import Foundation

// Offline comparison of the old GPS-led speed filter and SpeedFusion, on
// simulated drives with realistic phone-sensor errors:
//   accelerometer bias 0.04 m/s² drifting, white noise 0.25 m/s², road vibration,
//   a 3% slope section, GPS at 1 Hz trailing reality by 0.9 s with 0.2 m/s noise,
//   and a 12 s GPS dropout (tunnel).
// Build/run: Tools/fusion_test.sh

struct Rng { var s: UInt64 = 0x1234_5678_9abc
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double { let u = max(next(), 1e-12), v = next(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) }
}

/// The filter the app shipped with: integrate acceleration, pull hard to each GPS fix as if it were current.
struct OldFilter {
    var speed = 0.0, varV = 4.0
    mutating func predict(_ a: Double, dt: Double) { speed = max(speed + a * dt, 0); varV += 0.3 * dt }
    mutating func gps(_ z: Double, acc: Double) { let r = max(acc, 0.2) * max(acc, 0.2); let k = varV / (varV + r); speed = max(speed + k * (z - speed), 0); varV *= 1 - k }
}

func run(_ scenario: DriveScenario, repeats: Int) {
    var rng = Rng()
    let sim = SimulatedDrive(scenario: scenario)
    let dt = 0.01, gpsLag = 0.9
    var truth: [Double] = [], old: [Double] = [], new: [Double] = []
    var oldF = OldFilter(), newF = SpeedFusion()
    var t = 0.0, bias = 0.04, lastFix = 0.0
    var truthHistory: [(Double, Double)] = []
    var r = 0
    while r < repeats {
        if sim.finished { r += 1; if r == repeats { break }; sim.reset(scenario) }
        let st = sim.step(dt: dt)
        t += dt
        bias += rng.gauss() * 0.002 * dt.squareRoot()
        let slope = (t.truncatingRemainder(dividingBy: 60) > 30) ? 9.81 * 0.03 : 0
        let vibration = st.speed > 0.3 ? rng.gauss() * 0.35 : rng.gauss() * 0.02
        let aMeas = st.accel + bias + slope + rng.gauss() * 0.25 + vibration
        oldF.predict(aMeas, dt: dt)
        newF.predict(acceleration: aMeas, at: t, dt: dt)
        truthHistory.append((t, st.speed))
        let inTunnel = t.truncatingRemainder(dividingBy: 90) > 70 && t.truncatingRemainder(dividingBy: 90) < 82
        if t - lastFix >= 1, !inTunnel {
            lastFix = t
            // GPS reports the speed from gpsLag seconds ago, timestamped now.
            let idx = max(truthHistory.count - 1 - Int(gpsLag / dt), 0)
            let z = max(truthHistory[idx].1 + rng.gauss() * 0.2, 0)
            oldF.gps(z, acc: 0.5)
            newF.gps(speed: z, accuracy: 0.5, measuredAt: t)
        }
        truth.append(st.speed); old.append(oldF.speed); new.append(newF.speed)
    }

    func rms(_ e: [Double]) -> Double { (e.map { $0 * $0 }.reduce(0, +) / Double(e.count)).squareRoot() }
    func lag(_ est: [Double]) -> Double {
        // Shift (in s) that best aligns the estimate with the truth.
        var best = (0, Double.infinity)
        for s in stride(from: 0, through: 200, by: 2) {
            let e = (s..<truth.count).map { est[$0] - truth[$0 - s] }
            let v = rms(e); if v < best.1 { best = (s, v) }
        }
        return Double(best.0) * dt
    }
    let eOld = zip(old, truth).map { $0 - $1 }, eNew = zip(new, truth).map { $0 - $1 }
    print(String(format: "%-18@ old: rms %.2f m/s (%.1f km/h) max %.1f lag %.2fs | new: rms %.2f m/s (%.1f km/h) max %.1f lag %.2fs",
                 scenario.name as NSString,
                 rms(eOld), rms(eOld) * 3.6, eOld.map(abs).max()!, lag(old),
                 rms(eNew), rms(eNew) * 3.6, eNew.map(abs).max()!, lag(new)))
}

for id in ["lap", "traffic"] {
    run(DriveScenario.all.first { $0.id == id }!, repeats: 8)
}

// One continuous drive stitched from every scenario's pedal inputs, so the
// car never teleports between speeds: launches, cruise, kickdown, overrun,
// hard stops and traffic, with the tunnel and slope sections along the way.
var segments: [DriveScenario.Segment] = []
for _ in 0..<3 {
    for id in ["lap", "pullaway", "cruise", "kickdown", "liftoff", "braking", "traffic"] {
        segments += DriveScenario.all.first { $0.id == id }!.segments
    }
}
let composite = DriveScenario(id: "composite", name: "Continuous drive", icon: "", summary: "", initialSpeed: 0, segments: segments)
run(composite, repeats: 1)
