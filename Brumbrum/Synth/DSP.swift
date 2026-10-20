import Foundation

/// Small, allocation-free DSP building blocks for the render thread.

struct BiquadCoeffs {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    /// RBJ band-pass, constant 0 dB peak gain.
    static func bandpass(hz: Double, q: Double, sampleRate: Double) -> BiquadCoeffs {
        let w0 = 2 * Double.pi * min(hz, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.1))
        let a0 = 1 + alpha
        return BiquadCoeffs(b0: Float(alpha / a0), b1: 0, b2: Float(-alpha / a0),
                            a1: Float(-2 * cos(w0) / a0), a2: Float((1 - alpha) / a0))
    }
}

struct BiquadState {
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float, _ c: BiquadCoeffs) -> Float {
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// Zavalishin TPT state-variable filter; stable under fast cutoff modulation.
struct SVF {
    var ic1: Float = 0, ic2: Float = 0
    var a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1

    mutating func set(cutoff: Float, q: Float, sampleRate: Float) {
        let fc = min(max(cutoff, 10), sampleRate * 0.45)
        let g = tanf(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.05)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    /// Returns (low, band).
    @inline(__always)
    mutating func tick(_ x: Float) -> (Float, Float) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1)
    }
}

/// xorshift32: fast, deterministic, allocation-free noise.
struct Noise {
    var s: UInt32
    init(seed: UInt32) { s = seed == 0 ? 0x9E37_79B9 : seed }

    @inline(__always)
    mutating func next() -> UInt32 {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return s
    }

    /// Uniform in [-1, 1).
    @inline(__always)
    mutating func white() -> Float { Float(Int32(bitPattern: next())) * (1.0 / 2_147_483_648.0) }

    /// Uniform in [0, 1).
    @inline(__always)
    mutating func unit() -> Float { Float(next() >> 8) * (1.0 / 16_777_216.0) }
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

/// One-pole smoothing coefficient for a time constant in seconds.
@inline(__always) func smoothingCoeff(seconds: Float, sampleRate: Float) -> Float {
    1 - expf(-1 / max(seconds * sampleRate, 1))
}

/// PolyBLEP correction for naive sawtooth discontinuities.
@inline(__always) func polyBlep(_ t: Float, _ dt: Float) -> Float {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}
