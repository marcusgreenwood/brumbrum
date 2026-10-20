import Foundation

/// Plain-old-data view of an engine for the render thread: no references,
/// no Swift arrays, nothing that can retain, release or allocate.
struct SynthParams {
    static let maxCylinders = 16
    static let maxResonances = 6
    static let maxOrders = 12
    static let tableSize = 128

    var family: Int32 = 0                 // 0 combustion, 1 synthetic
    var structureKey: Int = 0
    var sampleRate: Float = 48000

    // Geometry
    var cylinders: Int32 = 0
    var banks: Int32 = 1
    var cycleDegrees: Double = 720
    var firingAngles: UnsafeMutablePointer<Double>
    var cylBank: UnsafeMutablePointer<Int32>
    var cylGain: UnsafeMutablePointer<Float>

    // Excitation
    var sharpZero: Float = 0.3, sharpFull: Float = 0.9
    var gainZero: Float = 0.2, gainFull: Float = 1

    // Exhaust
    var pipeDelaySamples: Float = 0
    var pipeFeedback: Float = 0
    var resCount: Int32 = 0
    var resCoeffs: UnsafeMutablePointer<BiquadCoeffs>
    var resGain: UnsafeMutablePointer<Float>
    var crackleDensity: Float = 0, crackleGain: Float = 0, crackleThreshold: Float = -0.3

    // Intake
    var intakeGain: Float = 0, intakeCutIdle: Float = 300, intakeCutRedline: Float = 3000, intakeLoadSens: Float = 0.8

    // Orders
    var orderCount: Int32 = 0
    var orderMult: UnsafeMutablePointer<Float>
    var orderTable: UnsafeMutablePointer<Float>   // orderCount × tableSize gains over 0…tableMaxRpm
    var tableMaxRpm: Float = 10000

    // Turbo
    var hasTurbo = false
    var spoolRate: Float = 0, maxBoost: Float = 1, whistleHz: Float = 0, blowoffGain: Float = 0

    // Mix and range
    var masterGain: Float = 0.8, exhaustToIntake: Float = 0.7, windGain: Float = 0.2
    var idleRpm: Float = 800, redlineRpm: Float = 7000
    var limiterSoft = false, limiterHz: Float = 18, limiterDepth: Float = 0.9

    // Synthetic generator
    var genType: Int32 = 0                // 0 fm, 1 saw, 2 formant
    var genBaseOrder: Float = 4, fmRatio: Float = 1.5, fmIdx0: Float = 0.5, fmIdx1: Float = 2
    var detuneCents: Float = 10, genVoices: Int32 = 3
    var formantLow: Float = 400, formantHigh: Float = 3000, formantQ: Float = 2, genGain: Float = 0.6
}

/// Owns the memory behind a `SynthParams`. Built on the main thread, handed to
/// the kernel by pointer, and kept alive by the owner until the kernel has
/// certainly stopped reading it.
final class SynthProgram {
    let params: UnsafeMutablePointer<SynthParams>
    let definition: EngineDefinition

    init(definition def: EngineDefinition, sampleRate: Double) {
        definition = def
        let p = SynthParams(
            firingAngles: .allocate(capacity: SynthParams.maxCylinders),
            cylBank: .allocate(capacity: SynthParams.maxCylinders),
            cylGain: .allocate(capacity: SynthParams.maxCylinders),
            resCoeffs: .allocate(capacity: SynthParams.maxResonances),
            resGain: .allocate(capacity: SynthParams.maxResonances),
            orderMult: .allocate(capacity: SynthParams.maxOrders),
            orderTable: .allocate(capacity: SynthParams.maxOrders * SynthParams.tableSize))
        params = .allocate(capacity: 1)
        params.initialize(to: p)
        params.pointee.firingAngles.initialize(repeating: 0, count: SynthParams.maxCylinders)
        params.pointee.cylBank.initialize(repeating: 0, count: SynthParams.maxCylinders)
        params.pointee.cylGain.initialize(repeating: 1, count: SynthParams.maxCylinders)
        params.pointee.resCoeffs.initialize(repeating: BiquadCoeffs(), count: SynthParams.maxResonances)
        params.pointee.resGain.initialize(repeating: 0, count: SynthParams.maxResonances)
        params.pointee.orderMult.initialize(repeating: 0, count: SynthParams.maxOrders)
        params.pointee.orderTable.initialize(repeating: 0, count: SynthParams.maxOrders * SynthParams.tableSize)
        fill(def, sampleRate: sampleRate)
    }

    deinit {
        let p = params.pointee
        p.firingAngles.deallocate(); p.cylBank.deallocate(); p.cylGain.deallocate()
        p.resCoeffs.deallocate(); p.resGain.deallocate()
        p.orderMult.deallocate(); p.orderTable.deallocate()
        params.deallocate()
    }

    private func fill(_ def: EngineDefinition, sampleRate sr: Double) {
        var p = params.pointee
        p.sampleRate = Float(sr)
        p.family = def.family == .combustion ? 0 : 1
        p.idleRpm = Float(def.range.idleRpm)
        p.redlineRpm = Float(def.range.redlineRpm)
        p.limiterSoft = def.range.limiter.mode == "softCut"
        p.limiterHz = Float(def.range.limiter.cutHz)
        p.limiterDepth = Float(min(max(def.range.limiter.depth, 0), 1))

        // Per-instance cylinder imbalance, fixed for a given engine id.
        var rng = Noise(seed: Self.hash(def.id))
        if let g = def.geometry, def.family == .combustion {
            let n = min(g.cylinders, SynthParams.maxCylinders)
            let variance = Float(def.excitation?.cylinderVariance ?? 0)
            var cyl: [(angle: Double, bank: Int32, gain: Float)] = []
            for i in 0..<n {
                let jitter = Double(rng.white() * variance * 60)        // ±degrees
                var a = g.firingAngles[i] + jitter
                a = a.truncatingRemainder(dividingBy: g.cycleDegrees)
                if a < 0 { a += g.cycleDegrees }
                cyl.append((a, Int32(g.bankOf[i]), 1 + rng.white() * variance * 3))
            }
            cyl.sort { $0.angle < $1.angle }
            for (i, c) in cyl.enumerated() {
                p.firingAngles[i] = c.angle
                p.cylBank[i] = c.bank
                p.cylGain[i] = c.gain
            }
            p.cylinders = Int32(n)
            p.banks = Int32(min(max(g.banks, 1), 2))
            p.cycleDegrees = g.cycleDegrees
        } else {
            p.cylinders = 0
            p.banks = 1
        }

        if let e = def.excitation {
            p.sharpZero = Float(e.grainSharpness.atZeroLoad)
            p.sharpFull = Float(e.grainSharpness.atFullLoad)
            p.gainZero = Float(e.grainGain.atZeroLoad)
            p.gainFull = Float(e.grainGain.atFullLoad)
        }

        if let ex = def.exhaust {
            p.pipeDelaySamples = Float(ex.pipeLengthMs / 1000 * sr)
            p.pipeFeedback = Float(ex.pipeFeedback)
            let res = ex.resonances.prefix(SynthParams.maxResonances)
            p.resCount = Int32(res.count)
            for (i, r) in res.enumerated() {
                p.resCoeffs[i] = .bandpass(hz: r.hz, q: r.q, sampleRate: sr)
                p.resGain[i] = Float(r.gain)
            }
            if let o = ex.overrun {
                p.crackleDensity = Float(o.crackleDensity)
                p.crackleGain = Float(o.gain)
                p.crackleThreshold = Float(o.thresholdLoad)
            } else {
                p.crackleDensity = 0
            }
        } else {
            p.resCount = 0
            p.pipeDelaySamples = 0
            p.crackleDensity = 0
        }

        p.intakeGain = Float(def.intake.noiseGain)
        p.intakeCutIdle = Float(def.intake.cutoffHzAtIdle)
        p.intakeCutRedline = Float(def.intake.cutoffHzAtRedline)
        p.intakeLoadSens = Float(def.intake.loadSensitivity)

        let orders = def.orders.prefix(SynthParams.maxOrders)
        p.orderCount = Int32(orders.count)
        p.tableMaxRpm = Float(def.range.redlineRpm * 1.1)
        for (i, o) in orders.enumerated() {
            p.orderMult[i] = Float(o.order)
            for j in 0..<SynthParams.tableSize {
                let rpm = Double(p.tableMaxRpm) * Double(j) / Double(SynthParams.tableSize - 1)
                p.orderTable[i * SynthParams.tableSize + j] = Float(EngineDefinition.interpolate(o.gain, at: rpm))
            }
        }

        if let t = def.turbo {
            p.hasTurbo = true
            p.spoolRate = Float(t.spoolRate)
            p.maxBoost = Float(max(t.maxBoost, 0.01))
            p.whistleHz = Float(t.whistleHzAtMaxBoost)
            p.blowoffGain = Float(t.blowoffGain)
        } else {
            p.hasTurbo = false
        }

        p.masterGain = Float(def.mix.masterGain)
        p.exhaustToIntake = Float(def.mix.exhaustToIntake)
        p.windGain = Float(def.mix.windGain)

        if let g = def.generator {
            p.genType = g.type == "saw" ? 1 : (g.type == "formant" ? 2 : 0)
            p.genBaseOrder = Float(g.baseOrder)
            p.fmRatio = Float(g.fmRatio)
            p.fmIdx0 = Float(g.fmIndexAtZeroLoad)
            p.fmIdx1 = Float(g.fmIndexAtFullLoad)
            p.detuneCents = Float(g.detuneCents)
            p.genVoices = Int32(min(max(g.voices, 1), 7))
            p.formantLow = Float(g.formantLowHz)
            p.formantHigh = Float(g.formantHighHz)
            p.formantQ = Float(g.formantQ)
            p.genGain = Float(g.gain)
        }

        // State that depends on these must be reset when they change.
        var h = Hasher()
        h.combine(p.family); h.combine(p.cylinders); h.combine(p.banks); h.combine(p.genVoices)
        p.structureKey = h.finalize()
        params.pointee = p
    }

    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }
}
