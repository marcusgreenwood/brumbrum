import Foundation
import AVFoundation
import Accelerate

/// Measures output latency on the current route by playing a sweep through the
/// speakers, recording it on the phone's microphone and cross-correlating.
///
/// Round trip − `AVAudioSession.inputLatency` ≈ output-path latency. Acoustic
/// travel across a cabin (~3 ms) is ignored.
final class LatencyMeasurer {
    enum Failure: LocalizedError {
        case noPermission, noInput, weakCorrelation(Double), engine(Error)
        var errorDescription: String? {
            switch self {
            case .noPermission: return "Microphone permission is required to measure latency."
            case .noInput: return "No microphone input was recorded."
            case .weakCorrelation(let q): return String(format: "The sweep could not be found in the recording (quality %.1f). Try a quieter cabin or higher volume.", q)
            case .engine(let e): return e.localizedDescription
            }
        }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    /// Returns output latency in seconds. Caller must have stopped the main engine.
    static func measure() async throws -> Double {
        guard await requestPermission() else { throw Failure.noPermission }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothA2DP])
        try session.setActive(true)
        defer {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw Failure.noInput }
        let sr = inFormat.sampleRate

        // Exponential sweep 300 Hz → 6 kHz, 1 s, with short fades.
        let sweepLen = Int(sr)
        let f0 = 300.0, f1 = 6000.0
        let k = log(f1 / f0)
        var sweep = [Float](repeating: 0, count: sweepLen)
        for i in 0..<sweepLen {
            let t = Double(i) / sr
            let phase = 2 * Double.pi * f0 * (exp(t * k) - 1) / k
            let fade = min(1, min(Double(i), Double(sweepLen - i)) / (0.01 * sr))
            sweep[i] = Float(sin(phase) * fade * 0.7)
        }

        let player = AVAudioPlayerNode()
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(sweepLen))!
        buffer.frameLength = AVAudioFrameCount(sweepLen)
        sweep.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: sweepLen) }

        let recorder = RecordingSink()
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buf, when in
            recorder.append(buf, when: when)
        }
        do { try engine.start() } catch { throw Failure.engine(error) }

        // Schedule the sweep a little in the future at a known host time.
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.4)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: startHost))
        try await Task.sleep(nanoseconds: 2_400_000_000)
        input.removeTap(onBus: 0)
        engine.stop()

        guard let (recording, recStartHost) = recorder.result(), recording.count > sweepLen else { throw Failure.noInput }

        // Correlate at a quarter rate: plenty of resolution, far less work.
        let dec = 4
        let ref = decimate(sweep, by: dec)
        let sig = decimate(recording, by: dec)
        let lags = sig.count - ref.count
        guard lags > 10 else { throw Failure.noInput }
        var corr = [Float](repeating: 0, count: lags)
        sig.withUnsafeBufferPointer { s in
            ref.withUnsafeBufferPointer { r in
                vDSP_conv(s.baseAddress!, 1, r.baseAddress!, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(ref.count))
            }
        }
        var absCorr = corr.map { abs($0) }
        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(&absCorr, 1, &peak, &peakIndex, vDSP_Length(lags))
        let sorted = absCorr.sorted()
        let median = max(sorted[sorted.count / 2], 1e-9)
        let quality = Double(peak / median)
        guard quality > 8 else { throw Failure.weakCorrelation(quality) }

        let recStart = AVAudioTime.seconds(forHostTime: recStartHost)
        let playStart = AVAudioTime.seconds(forHostTime: startHost)
        let arrival = recStart + Double(Int(peakIndex) * dec) / sr
        let roundTrip = arrival - playStart
        let output = roundTrip - session.inputLatency
        return min(max(output, 0), 1.0)
    }

    private static func decimate(_ x: [Float], by n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count / n)
        for i in 0..<out.count {
            var s: Float = 0
            for j in 0..<n { s += x[i * n + j] }
            out[i] = s / Float(n)
        }
        return out
    }
}

private final class RecordingSink {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var startHost: UInt64?

    func append(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let ch = buf.floatChannelData?[0] else { return }
        lock.lock(); defer { lock.unlock() }
        if startHost == nil, when.isHostTimeValid { startHost = when.hostTime }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }

    func result() -> ([Float], UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let h = startHost else { return nil }
        return (samples, h)
    }
}
