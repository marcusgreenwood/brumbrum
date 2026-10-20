import Foundation

/// An engine is data. Everything the synthesiser and powertrain need lives here,
/// decoded from the JSON format described in the spec.
struct EngineDefinition: Codable, Identifiable, Hashable {
    enum Family: String, Codable, CaseIterable { case combustion, synthetic }

    struct Geometry: Codable, Hashable {
        var cylinders: Int
        var strokes: Int
        var banks: Int
        var cycleDegrees: Double
        var firingAngles: [Double]
        var bankOf: [Int]
    }

    struct Limiter: Codable, Hashable {
        var mode: String          // "hardCut" | "softCut"
        var cutHz: Double
        var depth: Double
    }

    struct RangeSpec: Codable, Hashable {
        var idleRpm: Double
        var idleWanderRpm: Double
        var redlineRpm: Double
        var limiter: Limiter
    }

    struct Drivetrain: Codable, Hashable {
        var mode: String          // "geared" | "direct"
        var gearRatios: [Double]
        var finalDrive: Double
        var upshiftRpm: Double
        var downshiftRpm: Double
        var shiftMs: Double
        var launchSlip: Double
        var topSpeedKph: Double?

        var isDirect: Bool { mode == "direct" }
    }

    struct LoadPair: Codable, Hashable {
        var atZeroLoad: Double
        var atFullLoad: Double
    }

    struct Excitation: Codable, Hashable {
        var grainSharpness: LoadPair
        var grainGain: LoadPair
        var cylinderVariance: Double
    }

    struct Generator: Codable, Hashable {
        var type: String          // "fm" | "saw" | "formant"
        var baseOrder: Double
        var fmRatio: Double
        var fmIndexAtZeroLoad: Double
        var fmIndexAtFullLoad: Double
        var detuneCents: Double
        var voices: Int
        var formantLowHz: Double
        var formantHighHz: Double
        var formantQ: Double
        var gain: Double
    }

    struct Resonance: Codable, Hashable {
        var hz: Double
        var q: Double
        var gain: Double
    }

    struct Overrun: Codable, Hashable {
        var crackleDensity: Double
        var gain: Double
        var thresholdLoad: Double
    }

    struct Exhaust: Codable, Hashable {
        var pipeLengthMs: Double
        var pipeFeedback: Double
        var resonances: [Resonance]
        var overrun: Overrun?
    }

    struct Intake: Codable, Hashable {
        var noiseGain: Double
        var cutoffHzAtIdle: Double
        var cutoffHzAtRedline: Double
        var loadSensitivity: Double
    }

    struct Order: Codable, Hashable {
        var order: Double
        /// Breakpoints of [rpm, gain], linearly interpolated.
        var gain: [[Double]]
    }

    struct Turbo: Codable, Hashable {
        var spoolRate: Double
        var maxBoost: Double
        var whistleHzAtMaxBoost: Double
        var blowoffGain: Double
    }

    struct Mix: Codable, Hashable {
        var masterGain: Double
        var exhaustToIntake: Double
        var windGain: Double
    }

    var id: String
    var name: String
    var family: Family
    var version: Int
    var geometry: Geometry?
    var range: RangeSpec
    var drivetrain: Drivetrain
    var excitation: Excitation?
    var generator: Generator?
    var exhaust: Exhaust?
    var intake: Intake
    var orders: [Order]
    var turbo: Turbo?
    var mix: Mix
}

// MARK: - Validation

struct EngineValidationError: LocalizedError {
    var problems: [String]
    var errorDescription: String? { problems.joined(separator: "\n") }
}

extension EngineDefinition {
    /// Fail loudly at load time, never in the audio callback.
    func validate() throws {
        var p: [String] = []
        if id.isEmpty { p.append("id is empty") }
        if range.idleRpm <= 0 { p.append("idleRpm must be positive") }
        if range.redlineRpm <= range.idleRpm * 1.5 { p.append("redlineRpm must be well above idleRpm") }
        if range.redlineRpm > 20000 { p.append("redlineRpm above 20000") }

        switch family {
        case .combustion:
            if let g = geometry {
                if g.cylinders < 1 || g.cylinders > 16 { p.append("cylinders must be 1–16") }
                if g.banks < 1 || g.banks > 2 { p.append("banks must be 1 or 2") }
                if g.firingAngles.count != g.cylinders { p.append("firingAngles must have length cylinders (\(g.cylinders))") }
                if g.bankOf.count != g.cylinders { p.append("bankOf must have length cylinders (\(g.cylinders))") }
                if g.firingAngles.contains(where: { $0 < 0 || $0 >= g.cycleDegrees }) { p.append("every firing angle must lie in [0, cycleDegrees)") }
                if g.bankOf.contains(where: { $0 < 0 || $0 >= g.banks }) { p.append("bankOf entries must be < banks") }
                if g.cycleDegrees != 360 && g.cycleDegrees != 720 { p.append("cycleDegrees must be 360 or 720") }
            } else {
                p.append("combustion engines need a geometry block")
            }
            if excitation == nil { p.append("combustion engines need an excitation block") }
            if exhaust == nil { p.append("combustion engines need an exhaust block") }
        case .synthetic:
            if generator == nil { p.append("synthetic engines need a generator block") }
            if let g = generator, !["fm", "saw", "formant"].contains(g.type) { p.append("generator.type must be fm, saw or formant") }
        }

        if let ex = exhaust {
            if ex.resonances.count > 6 { p.append("at most 6 exhaust resonances") }
            if ex.pipeLengthMs < 0 || ex.pipeLengthMs > 40 { p.append("pipeLengthMs must be 0–40") }
            if ex.pipeFeedback < 0 || ex.pipeFeedback >= 0.95 { p.append("pipeFeedback must be in [0, 0.95)") }
        }

        if !drivetrain.isDirect {
            let r = drivetrain.gearRatios
            if r.isEmpty { p.append("geared drivetrain needs gearRatios") }
            if zip(r, r.dropFirst()).contains(where: { $0 <= $1 }) { p.append("gearRatios must be strictly descending") }
            if drivetrain.downshiftRpm > drivetrain.upshiftRpm * 0.6 { p.append("downshiftRpm must be comfortably below upshiftRpm (≤ 60%)") }
            if drivetrain.upshiftRpm > range.redlineRpm { p.append("upshiftRpm must not exceed redlineRpm") }
            if drivetrain.finalDrive <= 0 { p.append("finalDrive must be positive") }
        }

        if orders.count > 12 { p.append("at most 12 orders") }
        for o in orders {
            if o.gain.isEmpty || o.gain.contains(where: { $0.count != 2 }) { p.append("order \(o.order): gain must be [[rpm, gain], …]") }
        }
        if !p.isEmpty { throw EngineValidationError(problems: p) }
    }

    /// Linear interpolation over [rpm, gain] breakpoints.
    static func interpolate(_ curve: [[Double]], at x: Double) -> Double {
        guard let first = curve.first, first.count == 2 else { return 0 }
        if x <= first[0] { return first[1] }
        for (a, b) in zip(curve, curve.dropFirst()) where x <= b[0] {
            let t = (x - a[0]) / max(b[0] - a[0], 1e-9)
            return a[1] + (b[1] - a[1]) * t
        }
        return curve.last![1]
    }

    var summary: String {
        switch family {
        case .synthetic: return "Synthetic · direct drive"
        case .combustion:
            let cyl = geometry?.cylinders ?? 0
            let turboText = turbo != nil ? " · turbo" : ""
            return "\(cyl) cyl · \(Int(range.redlineRpm)) rpm redline\(turboText)"
        }
    }
}
