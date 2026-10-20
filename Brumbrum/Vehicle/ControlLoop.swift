import Foundation
import QuartzCore

enum DriveMode: String, Equatable {
    case off, live, testDrive, preview
}

/// Everything the UI shows, published ~30 times a second.
struct TelemetrySnapshot {
    var mode: DriveMode = .off
    var rpm = 0.0
    var load = 0.0
    var speed = 0.0
    var accel = 0.0
    var jerk = 0.0
    var confidence = 0.0
    var gear = 0
    var shifting = false
    var limiter = false
    var throttle = 0.0
    var brake = 0.0
    var scenarioLabel = ""
    var scenarioProgress = 0.0
    var scenarioFinished = false
    var sensors = SensorEstimator.Diagnostics()
    var predictionHorizon = 0.0
    var gate = 0.0
    var blipping = false
    var logging = false
}

/// The 100 Hz control thread: vehicle source → prediction → powertrain →
/// lock-free hand-off to the audio thread. Runs above the audio boundary, so it
/// may allocate and lock freely.
final class ControlLoop {
    struct Config {
        var mode: DriveMode = .off
        var muted = false
        var suspended = false            // interruptions, engine switches
        var fadeSeconds = 0.25
        var level = 0.7
        var ceiling = 0.85
        var speedCap = true
        var latency = 0.15
        var predictive = true
        var previewRpm = 1000.0
        var previewLoad = 0.0
        var previewAuto = true
        var manualThrottle = 0.0
        var manualBrake = 0.0
        var blipCount = 0                // each increment fires one throttle blip
        var logging = false
    }

    let controls: TripleBuffer<ControlFrame>
    let sensor = SensorEstimator()
    var onTelemetry: ((TelemetrySnapshot) -> Void)?

    private let lock = NSLock()
    private var config = Config()
    private var pendingEngine: EngineDefinition?
    private var pendingScenario: DriveScenario?
    private var resetAMax = false

    private let queue = DispatchQueue(label: "brumbrum.control", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var powertrain: Powertrain
    private let sim = SimulatedDrive(scenario: DriveScenario.all[0])
    private var aMax: AMaxCurve
    private var lastTick = CACurrentMediaTime()
    private var previewT = 0.0
    private var tickCount = 0
    private var lastSaved = CACurrentMediaTime()
    private var lastBlipCount = 0
    private var blipT = 99.0
    private var logger: DriveLogger?
    private var lastFixCount = 0

    static let aMaxKey = "aMaxCurve"

    init(controls: TripleBuffer<ControlFrame>, engine: EngineDefinition) {
        self.controls = controls
        powertrain = Powertrain(def: engine)
        if let data = UserDefaults.standard.data(forKey: Self.aMaxKey),
           let curve = try? JSONDecoder().decode(AMaxCurve.self, from: data),
           curve.buckets.count == AMaxCurve.bucketCount {
            aMax = curve
        } else {
            aMax = .seeded
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        lastTick = CACurrentMediaTime()
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func update(_ change: (inout Config) -> Void) {
        lock.lock(); change(&config); lock.unlock()
    }

    var currentConfig: Config {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    func setEngine(_ def: EngineDefinition) {
        lock.lock(); pendingEngine = def; lock.unlock()
    }

    func startScenario(_ s: DriveScenario) {
        lock.lock(); pendingScenario = s; lock.unlock()
    }

    func resetLearnedAMax() {
        lock.lock(); resetAMax = true; lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.aMaxKey)
    }

    // MARK: Control thread

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0.002), 0.05)
        lastTick = now
        tickCount += 1

        lock.lock()
        let cfg = config
        let newEngine = pendingEngine; pendingEngine = nil
        let newScenario = pendingScenario; pendingScenario = nil
        if resetAMax { aMax = .seeded; resetAMax = false }
        lock.unlock()

        if let s = newScenario { sim.reset(s) }
        if let e = newEngine { powertrain.setEngine(e, speed: cfg.mode == .testDrive ? sim.speed : 0) }

        if cfg.blipCount != lastBlipCount { lastBlipCount = cfg.blipCount; blipT = 0 } else { blipT += dt }
        let blipEnv = blipT < 1.2 ? exp(-blipT / 0.3) : 0

        var snap = TelemetrySnapshot()
        snap.mode = cfg.mode
        var frame = ControlFrame()
        var gateOpen = cfg.mode != .off && !cfg.muted && !cfg.suspended

        switch cfg.mode {
        case .off:
            break

        case .preview:
            // Garage audition: drive the synthesiser from a manual or automatic rpm ramp.
            let def = powertrain.def
            let idle = def.range.idleRpm, red = def.range.redlineRpm
            var rpm = cfg.previewRpm, load = cfg.previewLoad
            if cfg.previewAuto {
                previewT = (previewT + dt).truncatingRemainder(dividingBy: 10)
                let t = previewT
                switch t {
                case ..<1.5: rpm = idle; load = 0; snap.scenarioLabel = "Idle"
                case ..<5.5: rpm = idle + (red - idle) * (t - 1.5) / 4; load = 1; snap.scenarioLabel = "Full load ramp"
                case ..<6.3: rpm = red; load = 1; snap.scenarioLabel = "Limiter"
                default: rpm = max(idle, red - (red - idle) * (t - 6.3) / 3); load = -0.7; snap.scenarioLabel = "Overrun"
                }
                snap.scenarioProgress = t / 10
            }
            frame.rpm = Float(rpm); frame.load = Float(load)
            frame.limiter = rpm >= red - 1 ? 1 : 0
            snap.rpm = rpm; snap.load = load

        case .testDrive:
            sim.manualThrottle = cfg.manualThrottle
            sim.manualBrake = cfg.manualBrake
            let st = sim.step(dt: dt)
            let curve = AMaxCurve.physical
            let out = powertrain.update(state: st, load: st.accel / curve.value(at: st.speed), dt: dt)
            fill(&frame, &snap, out, st)
            snap.throttle = sim.throttle
            snap.brake = sim.brake
            snap.scenarioLabel = sim.currentLabel
            snap.scenarioProgress = sim.progress
            snap.scenarioFinished = sim.finished

        case .live:
            let (st, diag) = sensor.current()
            snap.sensors = diag
            if st.confidence > 0.6 { aMax.observe(speed: st.speed, accel: st.accel) }

            // Render the state the car will be in when the sound arrives.
            var predicted = st
            if cfg.predictive {
                let taper = 1 / (1 + abs(st.jerk) / 4)          // blend toward the present on sharp turns
                let L = min(cfg.latency, 0.25) * taper
                predicted.speed = max(st.speed + st.accel * L + 0.5 * st.jerk * L * L, 0)
                predicted.accel = st.accel + st.jerk * L
                snap.predictionHorizon = L
            }
            let out = powertrain.update(state: predicted, load: predicted.accel / aMax.value(at: predicted.speed), dt: dt)
            fill(&frame, &snap, out, st)
            if st.confidence < 0.2 || diag.mountMoved { gateOpen = false }

            if now - lastSaved > 30, let data = try? JSONEncoder().encode(aMax) {
                UserDefaults.standard.set(data, forKey: Self.aMaxKey)
                lastSaved = now
            }
        }

        // Blip: an instant rev, bypassing sensors and prediction, so the output
        // path's delay can be heard on its own. Opens the gate even uncalibrated.
        if blipEnv > 0.01 {
            let def = powertrain.def
            frame.rpm = min(frame.rpm + Float((def.range.redlineRpm - def.range.idleRpm) * 0.5 * blipEnv), Float(def.range.redlineRpm))
            frame.load = max(frame.load, Float(blipEnv * 0.95))
            frame.limiter = 0
            if cfg.mode != .off && !cfg.muted && !cfg.suspended { gateOpen = true }
            snap.rpm = Double(frame.rpm)
            snap.blipping = true
        }

        // Level: user level under a hard ceiling, minus a speed-dependent cap that
        // counters the car's own speed-dependent volume compensation.
        var volume = min(cfg.level, 1) * min(cfg.ceiling, 0.95)
        if cfg.speedCap { volume *= 1 - 0.35 * min(Double(frame.speed) / 40, 1) }
        frame.volume = Float(volume)
        frame.gate = gateOpen ? 1 : 0
        frame.fadeSeconds = Float(cfg.fadeSeconds)
        frame.popCounter = powertrain.popCounter
        frame.blowoffCounter = powertrain.blowoffCounter
        controls.write(frame)

        // Drive log, for tuning against real data.
        if cfg.logging && cfg.mode != .off {
            if logger == nil { logger = DriveLogger() }
            let d = snap.sensors
            let fixNew = d.gpsFixCount != lastFixCount
            lastFixCount = d.gpsFixCount
            logger?.write(DriveLogger.Row(
                time: now, mode: cfg.mode.rawValue, rawAccel: d.rawAccel, accel: snap.accel, bias: d.bias,
                speed: snap.speed, speedStd: d.speedStdDev, stationary: d.stationary,
                gpsSpeed: d.gpsSpeed, gpsAccuracy: d.gpsAccuracy, gpsNew: fixNew, gpsInnovation: d.gpsInnovation,
                rpm: Double(frame.rpm), load: Double(frame.load), gear: snap.gear, confidence: snap.confidence,
                gate: gateOpen ? 1 : 0, blip: blipT == 0, latency: cfg.latency, horizon: snap.predictionHorizon))
        } else if logger != nil {
            logger = nil      // closes the file
        }
        snap.logging = logger != nil

        if tickCount % 3 == 0, let cb = onTelemetry {
            snap.gate = gateOpen ? 1 : 0
            DispatchQueue.main.async { cb(snap) }
        }
    }

    private func fill(_ frame: inout ControlFrame, _ snap: inout TelemetrySnapshot, _ out: PowertrainOutput, _ st: VehicleState) {
        frame.rpm = Float(out.rpm)
        frame.load = Float(out.load)
        frame.speed = Float(st.speed)
        frame.shiftCut = Float(out.shiftCut)
        frame.limiter = out.limiter ? 1 : 0
        snap.rpm = out.rpm
        snap.load = out.load
        snap.gear = out.gear
        snap.shifting = out.shifting
        snap.limiter = out.limiter
        snap.speed = st.speed
        snap.accel = st.accel
        snap.jerk = st.jerk
        snap.confidence = st.confidence
    }
}
