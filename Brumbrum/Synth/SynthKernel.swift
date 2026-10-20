import Foundation
import Synchronization

/// The realtime engine-note renderer.
///
/// `render` runs on the audio thread: it never allocates, never locks and never
/// touches a Swift array or class reference. All state is preallocated here.
/// Control values arrive through `controls`; engine programs arrive through an
/// atomic pointer swap.
///
/// Layers (per the spec): firing-angle pulse train → per-bank exhaust resonators
/// and pipe comb → order sines → intake / wind / turbo noise beds. Synthetic
/// engines replace the pulse train with an FM or detuned-saw generator.
final class SynthKernel {
    static let maxVoices = 64
    static let delaySize = 4096
    static let subBlock = 32

    let sampleRate: Float
    let controls: TripleBuffer<ControlFrame>

    // Program hand-off (main → audio)
    private let pending = Atomic<Int>(0)
    private var p: UnsafeMutablePointer<SynthParams>?
    private var structureKey = Int.min
    private var liveProgram: SynthProgram?                       // main thread only
    private var retired: [(SynthProgram, CFAbsoluteTime)] = []   // main thread only

    // Combustion grain voices
    private let vAge: UnsafeMutablePointer<Float>
    private let vTau: UnsafeMutablePointer<Float>
    private let vAmp: UnsafeMutablePointer<Float>
    private let vNoise: UnsafeMutablePointer<Float>
    private let vBank: UnsafeMutablePointer<Int32>
    private let vActive: UnsafeMutablePointer<Bool>
    private var voiceCursor = 0

    // Exhaust per bank
    private let resState: UnsafeMutablePointer<BiquadState>      // 2 × maxResonances
    private let delayLine: UnsafeMutablePointer<Float>           // 2 × delaySize
    private var delayWrite = 0
    private var dcX0: Float = 0, dcY0: Float = 0, dcX1: Float = 0, dcY1: Float = 0

    // Crank
    private var thetaAbs: Double = 0
    private var cycleBase: Double = 0
    private var nextCyl = 0
    private var nextTarget: Double = 0

    // Smoothed controls
    private var rpm: Float = 800
    private var load: Float = 0
    private var speed: Float = 0
    private var gate: Float = 0
    private var volume: Float = 0
    private var shiftCut: Float = 0
    private var limiterEnv: Float = 0
    private var limAmp: Float = 1
    private var limPhase: Float = 0
    private var lastPop: UInt32 = 0
    private var lastBlow: UInt32 = 0

    // Orders
    private let orderPhase: UnsafeMutablePointer<Float>
    private let orderGainNow: UnsafeMutablePointer<Float>

    // Noise beds, turbo, generator
    private var noise = Noise(seed: 0x1234_5678)
    private var intakeF = SVF()
    private var windF = SVF()
    private var blowF = SVF()
    private var formantF = SVF()
    private var boost: Float = 0
    private var whistlePhase: Float = 0
    private var blowEnv: Float = 0
    private let genPhase: UnsafeMutablePointer<Float>
    private var fmCar: Float = 0
    private var fmMod: Float = 0

    /// Exposed for diagnostics (read racily from the UI; floats only).
    private(set) var peakLevel: Float = 0

    init(sampleRate: Double, controls: TripleBuffer<ControlFrame>) {
        self.sampleRate = Float(sampleRate)
        self.controls = controls
        let v = Self.maxVoices
        vAge = .allocate(capacity: v); vAge.initialize(repeating: 0, count: v)
        vTau = .allocate(capacity: v); vTau.initialize(repeating: 1, count: v)
        vAmp = .allocate(capacity: v); vAmp.initialize(repeating: 0, count: v)
        vNoise = .allocate(capacity: v); vNoise.initialize(repeating: 0, count: v)
        vBank = .allocate(capacity: v); vBank.initialize(repeating: 0, count: v)
        vActive = .allocate(capacity: v); vActive.initialize(repeating: false, count: v)
        resState = .allocate(capacity: 2 * SynthParams.maxResonances)
        resState.initialize(repeating: BiquadState(), count: 2 * SynthParams.maxResonances)
        delayLine = .allocate(capacity: 2 * Self.delaySize)
        delayLine.initialize(repeating: 0, count: 2 * Self.delaySize)
        orderPhase = .allocate(capacity: SynthParams.maxOrders)
        orderPhase.initialize(repeating: 0, count: SynthParams.maxOrders)
        orderGainNow = .allocate(capacity: SynthParams.maxOrders)
        orderGainNow.initialize(repeating: 0, count: SynthParams.maxOrders)
        genPhase = .allocate(capacity: 8)
        genPhase.initialize(repeating: 0, count: 8)
        blowF.set(cutoff: 2400, q: 1.2, sampleRate: self.sampleRate)
    }

    deinit {
        vAge.deallocate(); vTau.deallocate(); vAmp.deallocate(); vNoise.deallocate()
        vBank.deallocate(); vActive.deallocate()
        resState.deallocate(); delayLine.deallocate()
        orderPhase.deallocate(); orderGainNow.deallocate(); genPhase.deallocate()
    }

    // MARK: Main-thread API

    /// Hands a new engine to the audio thread. Old programs are kept alive for
    /// two seconds, long after the render thread has stopped reading them.
    func setProgram(_ program: SynthProgram) {
        let now = CFAbsoluteTimeGetCurrent()
        pending.store(Int(bitPattern: program.params), ordering: .releasing)
        if let old = liveProgram { retired.append((old, now)) }
        liveProgram = program
        retired.removeAll { now - $0.1 > 2 }
    }

    var currentProgram: SynthProgram? { liveProgram }

    // MARK: Audio thread

    private func resetState() {
        for i in 0..<Self.maxVoices { vActive[i] = false }
        for i in 0..<(2 * SynthParams.maxResonances) { resState[i] = BiquadState() }
        for i in 0..<(2 * Self.delaySize) { delayLine[i] = 0 }
        for i in 0..<SynthParams.maxOrders { orderPhase[i] = 0 }
        for i in 0..<8 { genPhase[i] = Float(i) * 0.137 }
        dcX0 = 0; dcY0 = 0; dcX1 = 0; dcY1 = 0
        thetaAbs = 0; cycleBase = 0; nextCyl = 0
        nextTarget = p.map { $0.pointee.cylinders > 0 ? $0.pointee.firingAngles[0] + 0.001 : 0 } ?? 0
        intakeF = SVF(); windF = SVF(); formantF = SVF()
        blowF.ic1 = 0; blowF.ic2 = 0
        boost = 0; blowEnv = 0; fmCar = 0; fmMod = 0
    }

    private func adopt(_ newP: UnsafeMutablePointer<SynthParams>) {
        let firstProgram = p == nil
        p = newP
        if newP.pointee.structureKey != structureKey {
            structureKey = newP.pointee.structureKey
            resetState()
        }
        if firstProgram { rpm = newP.pointee.idleRpm }
    }

    @inline(__always)
    private func spawn(bank: Int32, age: Float, tau: Float, amp: Float, noiseAmt: Float) {
        var slot = -1
        for i in 0..<Self.maxVoices where !vActive[i] { slot = i; break }
        if slot < 0 { slot = voiceCursor; voiceCursor = (voiceCursor + 1) % Self.maxVoices }
        vActive[slot] = true
        vAge[slot] = age
        vTau[slot] = max(tau, 0.5)
        vAmp[slot] = amp
        vNoise[slot] = noiseAmt
        vBank[slot] = bank
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        let bits = pending.exchange(0, ordering: .acquiring)
        if bits != 0, let np = UnsafeMutablePointer<SynthParams>(bitPattern: bits) { adopt(np) }
        let c = controls.read()

        guard let pp = p else {
            for i in 0..<frames { left[i] = 0; right?[i] = 0 }
            return
        }
        let P = pp.pointee
        let sr = sampleRate
        let invSr = 1 / sr
        let twoPi = 2 * Float.pi

        // Smoothers: every parameter is interpolated at audio rate.
        let cRpm = smoothingCoeff(seconds: 0.008, sampleRate: sr)
        let cLoad = smoothingCoeff(seconds: 0.012, sampleRate: sr)
        let cSpeed = smoothingCoeff(seconds: 0.1, sampleRate: sr)
        let cGate = smoothingCoeff(seconds: max(c.fadeSeconds, 0.005) / 3, sampleRate: sr)
        let cVol = smoothingCoeff(seconds: 0.05, sampleRate: sr)
        let cShift = smoothingCoeff(seconds: 0.006, sampleRate: sr)
        let cLim = smoothingCoeff(seconds: 0.002, sampleRate: sr)
        let cLimEnv = smoothingCoeff(seconds: 0.02, sampleRate: sr)
        let blowDecay = expf(-1 / (0.28 * sr))
        let targetRpm = clampf(c.rpm.isFinite ? c.rpm : P.idleRpm, 0, P.redlineRpm * 1.05)
        let targetLoad = clampf(c.load.isFinite ? c.load : 0, -1, 1)
        let isCombustion = P.family == 0 && P.cylinders > 0
        let banks = Int(P.banks)

        // One-shot events
        if c.popCounter != lastPop {
            lastPop = c.popCounter
            if isCombustion {
                let g = max(P.crackleGain, 0.25) * 1.6
                for k in 0..<3 {
                    spawn(bank: Int32(k % banks), age: -noise.unit() * 0.06 * sr - Float(k) * 0.012 * sr,
                          tau: 0.07e-3 * sr, amp: g * (0.6 + 0.6 * noise.unit()), noiseAmt: 0.9)
                }
            }
        }
        if c.blowoffCounter != lastBlow {
            lastBlow = c.blowoffCounter
            if P.hasTurbo && boost > 0.3 * P.maxBoost {
                blowEnv = boost / P.maxBoost
                boost *= 0.3
            }
        }

        var i = 0
        while i < frames {
            let n = min(Self.subBlock, frames - i)

            // Per-sub-block control-rate work: filter cutoffs and order gains.
            let rpmNorm = clampf((rpm - P.idleRpm) / max(P.redlineRpm - P.idleRpm, 1), 0, 1.1)
            let lpos = max(load, 0)
            let lneg = min(load, 0)
            intakeF.set(cutoff: lerp(P.intakeCutIdle, P.intakeCutRedline, rpmNorm) * (0.7 + 0.3 * lpos), q: 0.8, sampleRate: sr)
            windF.set(cutoff: 180 + speed * 14, q: 0.6, sampleRate: sr)
            if P.family == 1 {
                let fc = lerp(P.formantLow, P.formantHigh, powf(lpos, 0.7)) * (1 + 0.4 * lneg)
                formantF.set(cutoff: fc, q: P.formantQ, sampleRate: sr)
            }
            let tablePos = clampf(rpm / P.tableMaxRpm, 0, 1) * Float(SynthParams.tableSize - 1)
            let ti = min(Int(tablePos), SynthParams.tableSize - 2)
            let tf = tablePos - Float(ti)
            for o in 0..<Int(P.orderCount) {
                let base = o * SynthParams.tableSize + ti
                orderGainNow[o] = lerp(P.orderTable[base], P.orderTable[base + 1], tf)
            }

            for j in 0..<n {
                rpm += cRpm * (targetRpm - rpm)
                load += cLoad * (targetLoad - load)
                speed += cSpeed * (c.speed - speed)
                gate += cGate * (c.gate - gate)
                volume += cVol * (c.volume - volume)
                shiftCut += cShift * (c.shiftCut - shiftCut)
                limiterEnv += cLimEnv * (c.limiter - limiterEnv)

                let lp = max(load, 0)
                let ln = min(load, 0)
                let crankHz = rpm / 60

                // Rev limiter: a hard periodic gate or a softer stutter.
                limPhase += P.limiterHz * invSr
                if limPhase >= 1 { limPhase -= 1 }
                var limTarget: Float = 1
                var grainLimit: Float = 1
                if limiterEnv > 0.01 {
                    if P.limiterSoft {
                        limTarget = 1 - P.limiterDepth * limiterEnv * 0.5 * (1 - cosf(twoPi * limPhase))
                        grainLimit = limTarget
                    } else if limPhase >= 0.5 {
                        limTarget = 1 - P.limiterDepth * limiterEnv
                        grainLimit = limTarget
                    }
                }
                limAmp += cLim * (limTarget - limAmp)

                var exL: Float = 0, exR: Float = 0
                var source: Float = 0

                if isCombustion {
                    // 1. Excitation: crank-angle accumulator triggers a grain per firing,
                    //    carrying the fractional sample offset for sub-sample timing.
                    let dDeg = Double(crankHz * 360 * invSr)
                    if dDeg > 1e-9 {
                        let prev = thetaAbs
                        thetaAbs += dDeg
                        let cyls = Int(P.cylinders)
                        while nextTarget <= thetaAbs {
                            let frac = clampf(Float((nextTarget - prev) / dDeg), 0, 1)
                            let cyl = nextCyl
                            let sharp = clampf(lerp(P.sharpZero, P.sharpFull, lp) * (1 + 0.3 * ln), 0, 1)
                            let tauMs = lerp(1.6, 0.12, sharp)
                            let amp = lerp(P.gainZero, P.gainFull, lp) * (1 + 0.55 * ln) * P.cylGain[cyl]
                                * (1 - 0.92 * shiftCut) * grainLimit
                            spawn(bank: P.cylBank[cyl], age: 1 - frac, tau: tauMs * 1e-3 * sr, amp: amp, noiseAmt: 0.12 + 0.3 * lp)
                            nextCyl += 1
                            if nextCyl >= cyls { nextCyl = 0; cycleBase += P.cycleDegrees }
                            nextTarget = cycleBase + P.firingAngles[nextCyl]
                        }
                        if cycleBase > 1_000_000 {
                            thetaAbs -= cycleBase; nextTarget -= cycleBase; cycleBase = 0
                        }
                    }

                    // Overrun crackle on lift-off and regen.
                    if P.crackleDensity > 0 && load < P.crackleThreshold && rpm > P.idleRpm * 1.25 {
                        let depth = min(1, (P.crackleThreshold - load) / 0.3 + 0.3)
                        let prob = P.crackleDensity * 35 * invSr * depth * min(1, rpm / (P.idleRpm * 3))
                        if noise.unit() < prob {
                            spawn(bank: Int32(noise.next() % UInt32(banks)), age: 0, tau: 0.06e-3 * sr,
                                  amp: P.crackleGain * (0.5 + 0.9 * noise.unit()) * 1.4, noiseAmt: 0.9)
                        }
                    }

                    // Render active grains: x·e^(1−x)·(1−x/2) is DC-free with a rarefaction tail.
                    var b0: Float = 0, b1: Float = 0
                    for v in 0..<Self.maxVoices where vActive[v] {
                        let age = vAge[v]
                        if age >= 0 {
                            let x = age / vTau[v]
                            let e = expf(-0.5 * x)
                            let pulse = x * e * e * 2.718_281_8 * (1 - 0.5 * x)
                            let g = vAmp[v] * (pulse + vNoise[v] * e * noise.white())
                            if vBank[v] == 0 { b0 += g } else { b1 += g }
                            if x > 14 { vActive[v] = false }
                        }
                        vAge[v] = age + 1
                    }

                    // 2. Resonance: exhaust modes + pipe-length comb, per bank.
                    // Bank 1's pipe is a little longer, as real headers are; otherwise a
                    // mono fold-down would cancel a crossplane's half-orders.
                    for b in 0..<banks {
                        let D = b == 0 ? P.pipeDelaySamples : P.pipeDelaySamples * 1.13
                        let readPos = Float(delayWrite) - D
                        let input = b == 0 ? b0 : b1
                        var y = input * 0.3
                        for r in 0..<Int(P.resCount) {
                            y += P.resGain[r] * resState[b * SynthParams.maxResonances + r].process(input, P.resCoeffs[r])
                        }
                        let base = b * Self.delaySize
                        if D >= 1 {
                            var rp = readPos
                            if rp < 0 { rp += Float(Self.delaySize) }
                            let i0 = Int(rp) & (Self.delaySize - 1)
                            let i1 = (i0 + 1) & (Self.delaySize - 1)
                            let f = rp - floorf(rp)
                            let delayed = delayLine[base + i0] * (1 - f) + delayLine[base + i1] * f
                            y += P.pipeFeedback * delayed
                        }
                        delayLine[base + delayWrite] = y
                        // DC blocker
                        if b == 0 {
                            let o = y - dcX0 + 0.995 * dcY0; dcX0 = y; dcY0 = o; exL = o
                        } else {
                            let o = y - dcX1 + 0.995 * dcY1; dcX1 = y; dcY1 = o; exR = o
                        }
                    }
                    delayWrite = (delayWrite + 1) & (Self.delaySize - 1)
                    if banks == 1 { exR = exL }
                } else if P.family == 1 {
                    // Synthetic: FM or detuned saws, then a formant that opens with load.
                    let f0 = crankHz * P.genBaseOrder
                    let dt = min(f0 * invSr, 0.45)
                    var dry: Float = 0
                    let voices = Int(P.genVoices)
                    if P.genType == 0 {
                        fmMod += f0 * P.fmRatio * invSr; if fmMod >= 1 { fmMod -= floorf(fmMod) }
                        fmCar += dt; if fmCar >= 1 { fmCar -= 1 }
                        let idx = lerp(P.fmIdx0, P.fmIdx1, lp) * (1 + 0.5 * ln)
                        dry = sinf(twoPi * fmCar + idx * sinf(twoPi * fmMod))
                        // Detuned unison copies for width.
                        for k in 1..<max(voices, 1) {
                            let det = powf(2, (Float(k) - Float(voices) / 2) * P.detuneCents / 1200)
                            genPhase[k] += dt * det; if genPhase[k] >= 1 { genPhase[k] -= 1 }
                            dry += 0.35 * sinf(twoPi * genPhase[k] + idx * 0.5 * sinf(twoPi * fmMod))
                        }
                    } else {
                        for k in 0..<voices {
                            let spread = voices > 1 ? (Float(k) / Float(voices - 1) - 0.5) * 2 : 0
                            let ddt = dt * powf(2, spread * P.detuneCents / 1200)
                            var ph = genPhase[k] + ddt
                            if ph >= 1 { ph -= 1 }
                            genPhase[k] = ph
                            dry += (2 * ph - 1) - polyBlep(ph, ddt)
                        }
                        dry /= Float(max(voices, 1)).squareRoot()
                    }
                    let (_, band) = formantF.tick(dry)
                    let shaped = P.genType == 2 ? band * 1.8 : dry * 0.5 + band * 1.2
                    source = shaped * P.genGain * (0.55 + 0.45 * lp) * (1 + 0.45 * ln) * limAmp * 0.3
                }

                // 3. Order layer: harmonic sheen at fixed engine orders.
                var orders: Float = 0
                let nyq = 0.45 * sr
                for o in 0..<Int(P.orderCount) {
                    let f = P.orderMult[o] * crankHz
                    if f >= nyq { continue }
                    var ph = orderPhase[o] + f * invSr
                    if ph >= 1 { ph -= floorf(ph) }
                    orderPhase[o] = ph
                    orders += orderGainNow[o] * sinf(twoPi * ph)
                }
                orders *= 0.16 * (0.55 + 0.45 * lp) * (1 + 0.5 * ln) * limAmp * (1 - 0.6 * shiftCut)

                // 4. Noise beds: intake, wind/road, turbo.
                let (intakeLow, _) = intakeF.tick(noise.white())
                let intake = intakeLow * P.intakeGain * (0.2 + P.intakeLoadSens * lp) * (0.6 + 0.4 * rpmNorm)
                let (windLow, _) = windF.tick(noise.white())
                let s = speed / 45
                let wind = windLow * P.windGain * min(1, s * s) * 0.7

                var turbo: Float = 0
                if P.hasTurbo {
                    let target = P.maxBoost * lp * min(1, rpm / (P.idleRpm * 2.5))
                    boost += (target - boost) * min(P.spoolRate * invSr, 1)
                    let b = boost / P.maxBoost
                    let wf = P.whistleHz * b * (0.6 + 0.4 * rpmNorm)
                    whistlePhase += wf * invSr; if whistlePhase >= 1 { whistlePhase -= floorf(whistlePhase) }
                    turbo = sinf(twoPi * whistlePhase) * 0.03 * b * b
                    if blowEnv > 0.0005 {
                        let (_, bp) = blowF.tick(noise.white())
                        turbo += bp * blowEnv * P.blowoffGain * 0.8
                        blowEnv *= blowDecay
                    }
                }

                // Mix
                let e2i = P.exhaustToIntake
                let common = (isCombustion ? intake * (1 - e2i) * 2.2 : intake * 0.5) + source + orders + wind + turbo
                let exGain = e2i * 1.3
                var l = (common + (exL * 0.6 + exR * 0.4) * exGain) * P.masterGain * volume * gate
                var r = (common + (exL * 0.4 + exR * 0.6) * exGain) * P.masterGain * volume * gate

                // Never hand the amplifier a NaN or a full-scale spike.
                if !l.isFinite || !r.isFinite { resetState(); l = 0; r = 0 }
                l = 0.9 * tanhf(l / 0.9)
                r = 0.9 * tanhf(r / 0.9)
                left[i + j] = l
                right?[i + j] = r
                let a = max(abs(l), abs(r))
                if a > peakLevel { peakLevel = a } else { peakLevel *= 0.99995 }
            }
            i += n
        }
    }
}
