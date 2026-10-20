import Foundation

/// Scripted test drives: pedal inputs over time fed through a simple model of
/// the car, so every engine can be auditioned under launch, cruise, lift-off,
/// braking and kickdown without moving.
struct DriveScenario: Identifiable, Hashable {
    struct Segment: Hashable {
        var duration: Double
        var throttle: Double
        var brake: Double
        var label: String
    }

    var id: String
    var name: String
    var icon: String
    var summary: String
    var initialSpeed: Double     // m/s
    var segments: [Segment]

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    var isManual: Bool { segments.isEmpty }

    static let manual = DriveScenario(id: "manual", name: "Manual pedals", icon: "hand.tap",
                                      summary: "Hold the pedals yourself", initialSpeed: 0, segments: [])

    static let all: [DriveScenario] = [
        DriveScenario(id: "idle", name: "Idle", icon: "parkingsign.circle",
                      summary: "Standing still, engine ticking over", initialSpeed: 0,
                      segments: [.init(duration: 8, throttle: 0, brake: 0.2, label: "Idling")]),
        DriveScenario(id: "pullaway", name: "Gentle pull-away", icon: "tortoise",
                      summary: "Light throttle from rest, early shifts, settle to cruise", initialSpeed: 0,
                      segments: [.init(duration: 1.5, throttle: 0, brake: 0.2, label: "Idling"),
                                 .init(duration: 12, throttle: 0.22, brake: 0, label: "Light throttle"),
                                 .init(duration: 6, throttle: 0.06, brake: 0, label: "Cruise")]),
        DriveScenario(id: "launch", name: "Full-throttle launch", icon: "hare",
                      summary: "Flat out from a standstill through the gears", initialSpeed: 0,
                      segments: [.init(duration: 1.5, throttle: 0, brake: 0.3, label: "Staging"),
                                 .init(duration: 9, throttle: 1, brake: 0, label: "Full throttle"),
                                 .init(duration: 4, throttle: 0, brake: 0, label: "Lift-off")]),
        DriveScenario(id: "cruise", name: "Motorway cruise", icon: "road.lanes",
                      summary: "Steady 110 km/h with small throttle corrections", initialSpeed: 30.5,
                      segments: [.init(duration: 4, throttle: 0.09, brake: 0, label: "Cruise"),
                                 .init(duration: 3, throttle: 0.16, brake: 0, label: "Gentle push"),
                                 .init(duration: 5, throttle: 0.08, brake: 0, label: "Cruise")]),
        DriveScenario(id: "kickdown", name: "Kickdown overtake", icon: "arrow.up.forward",
                      summary: "Cruising, then floor it to pass", initialSpeed: 22,
                      segments: [.init(duration: 3, throttle: 0.08, brake: 0, label: "Cruise"),
                                 .init(duration: 5, throttle: 1, brake: 0, label: "Kickdown"),
                                 .init(duration: 4, throttle: 0.1, brake: 0, label: "Settle")]),
        DriveScenario(id: "liftoff", name: "Lift-off & regen", icon: "arrow.down.right",
                      summary: "Off the throttle at speed: overrun and crackle", initialSpeed: 33,
                      segments: [.init(duration: 2, throttle: 0.4, brake: 0, label: "Pulling"),
                                 .init(duration: 8, throttle: 0, brake: 0, label: "Overrun / regen")]),
        DriveScenario(id: "braking", name: "Hard braking", icon: "exclamationmark.octagon",
                      summary: "Heavy stop from speed, downshifts to idle", initialSpeed: 30,
                      segments: [.init(duration: 1, throttle: 0.1, brake: 0, label: "Cruise"),
                                 .init(duration: 4.5, throttle: 0, brake: 0.85, label: "Braking"),
                                 .init(duration: 3, throttle: 0, brake: 0.2, label: "Stopped")]),
        DriveScenario(id: "traffic", name: "Stop-and-go", icon: "car.2",
                      summary: "Creep, crawl and stop in traffic", initialSpeed: 0,
                      segments: [.init(duration: 2, throttle: 0.15, brake: 0, label: "Creep"),
                                 .init(duration: 2, throttle: 0, brake: 0.35, label: "Stop"),
                                 .init(duration: 3, throttle: 0.3, brake: 0, label: "Crawl"),
                                 .init(duration: 2.5, throttle: 0, brake: 0.4, label: "Stop"),
                                 .init(duration: 2, throttle: 0.2, brake: 0, label: "Creep"),
                                 .init(duration: 2, throttle: 0, brake: 0.5, label: "Stop")]),
        DriveScenario(id: "lap", name: "Full lap", icon: "flag.checkered",
                      summary: "Idle, launch, cruise, overrun, brake, idle", initialSpeed: 0,
                      segments: [.init(duration: 2.5, throttle: 0, brake: 0.2, label: "Idle"),
                                 .init(duration: 7, throttle: 1, brake: 0, label: "Launch"),
                                 .init(duration: 4, throttle: 0.1, brake: 0, label: "Cruise"),
                                 .init(duration: 3, throttle: 0.8, brake: 0, label: "Push"),
                                 .init(duration: 4, throttle: 0, brake: 0, label: "Overrun"),
                                 .init(duration: 4, throttle: 0, brake: 0.75, label: "Braking"),
                                 .init(duration: 3, throttle: 0, brake: 0.2, label: "Idle")]),
    ]
}

/// A crude longitudinal model of a ~2.3 t, ~500 kW EV. Only needs to be
/// plausible: it supplies speed, acceleration and jerk like the estimator would.
final class SimulatedDrive {
    private(set) var scenario: DriveScenario
    private(set) var time = 0.0
    private(set) var speed = 0.0
    private(set) var accel = 0.0
    private(set) var jerk = 0.0
    private(set) var throttle = 0.0
    private(set) var brake = 0.0
    private(set) var finished = false
    var manualThrottle = 0.0
    var manualBrake = 0.0

    init(scenario: DriveScenario) {
        self.scenario = scenario
        reset(scenario)
    }

    func reset(_ s: DriveScenario) {
        scenario = s
        time = 0; speed = s.initialSpeed; accel = 0; jerk = 0
        throttle = 0; brake = 0; finished = false
        manualThrottle = 0; manualBrake = 0
        if s.initialSpeed > 0, let first = s.segments.first { throttle = first.throttle }
    }

    var progress: Double { scenario.isManual ? 0 : min(time / max(scenario.duration, 0.01), 1) }

    var currentLabel: String {
        if scenario.isManual { return manualBrake > 0.05 ? "Braking" : (manualThrottle > 0.05 ? "Throttle" : "Coasting") }
        var t = time
        for seg in scenario.segments {
            if t < seg.duration { return seg.label }
            t -= seg.duration
        }
        return "Finished"
    }

    private func pedalTargets() -> (Double, Double) {
        if scenario.isManual { return (manualThrottle, manualBrake) }
        var t = time
        for seg in scenario.segments {
            if t < seg.duration { return (seg.throttle, seg.brake) }
            t -= seg.duration
        }
        return (0, 0.2)
    }

    static func aMaxCar(_ v: Double) -> Double { min(9.2, 215 / max(v, 1)) }

    func step(dt: Double) -> VehicleState {
        time += dt
        if !scenario.isManual && time >= scenario.duration { finished = true }
        let (tThrottle, tBrake) = pedalTargets()
        // Feet don't move instantly.
        throttle += max(min(tThrottle - throttle, 3.5 * dt), -5 * dt)
        brake += max(min(tBrake - brake, 4 * dt), -6 * dt)

        var a = throttle * Self.aMaxCar(speed)
        if speed > 0.05 {
            a -= brake * 10
            if throttle < 0.03 { a -= 1.1 * min(speed / 5, 1) }      // lift-off regen
            a -= 0.00035 * speed * speed + 0.12                       // drag and rolling resistance
        } else if a < brake * 10 {
            a = 0
        }
        if speed <= 0 && a < 0 { a = 0 }
        speed = max(speed + a * dt, 0)
        let newJerk = (a - accel) / max(dt, 1e-3)
        jerk += (newJerk - jerk) * min(dt * 20, 1)
        accel = a
        return VehicleState(speed: speed, accel: a, jerk: jerk, confidence: 1)
    }
}
