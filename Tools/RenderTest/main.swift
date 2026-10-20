import Foundation

// Offline harness: drives each preset through a test-drive scenario using the
// same powertrain + kernel as the app, writes WAVs and prints level stats.
// Build: Tools/render_test.sh

let sr = 48000.0
let args = CommandLine.arguments
let enginesDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "Brumbrum/Engines")
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/brumbrum-render")
let scenarioId = args.count > 3 ? args[3] : "lap"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writeWav(_ url: URL, _ l: [Float], _ r: [Float]) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let n = l.count
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 4))
    d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(n * 4))
    for i in 0..<n {
        u16(UInt16(bitPattern: Int16(max(-1, min(1, l[i])) * 32767)))
        u16(UInt16(bitPattern: Int16(max(-1, min(1, r[i])) * 32767)))
    }
    try! d.write(to: url)
}

let scenario = DriveScenario.all.first { $0.id == scenarioId } ?? DriveScenario.all[0]
let steadyRpm = Double(ProcessInfo.processInfo.environment["STEADY"] ?? "")
let files = try FileManager.default.contentsOfDirectory(at: enginesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }

for file in files {
    var def = try JSONDecoder().decode(EngineDefinition.self, from: Data(contentsOf: file))
    try def.validate()
    if let rpm = steadyRpm {
        // Pulse train + exhaust only, fixed rpm/load: for spectral checks.
        def.orders = []; def.intake.noiseGain = 0
        let controls = TripleBuffer(initial: ControlFrame(rpm: Float(rpm), load: 0.5, speed: 0, gate: 1, volume: 0.8))
        let kernel = SynthKernel(sampleRate: sr, controls: controls)
        kernel.setProgram(SynthProgram(definition: def, sampleRate: sr))
        let n = Int(sr) * 4
        let lb = UnsafeMutablePointer<Float>.allocate(capacity: n), rb = UnsafeMutablePointer<Float>.allocate(capacity: n)
        kernel.render(frames: n, left: lb, right: rb)
        writeWav(outDir.appendingPathComponent("\(def.id)-steady.wav"), Array(UnsafeBufferPointer(start: lb, count: n)), Array(UnsafeBufferPointer(start: rb, count: n)))
        continue
    }
    let controls = TripleBuffer(initial: ControlFrame())
    let kernel = SynthKernel(sampleRate: sr, controls: controls)
    kernel.setProgram(SynthProgram(definition: def, sampleRate: sr))
    let pt = Powertrain(def: def)
    let sim = SimulatedDrive(scenario: scenario)
    pt.setEngine(def, speed: sim.speed)
    let curve = AMaxCurve.physical

    let block = 480 // 10 ms control rate
    var L: [Float] = [], R: [Float] = []
    let lbuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let rbuf = UnsafeMutablePointer<Float>.allocate(capacity: block)
    var maxRpm = 0.0, maxGear = 0, segStats: [String: (Double, Float, Int)] = [:]
    var renderTime = 0.0
    var label = ""
    while !sim.finished {
        let st = sim.step(dt: 0.01)
        label = sim.currentLabel
        let load = st.accel / curve.value(at: st.speed)
        let out = pt.update(state: st, load: load, dt: 0.01)
        maxRpm = max(maxRpm, out.rpm); maxGear = max(maxGear, out.gear)
        controls.write(ControlFrame(rpm: Float(out.rpm), load: Float(out.load), speed: Float(st.speed), gate: 1,
                                    fadeSeconds: 0.1, volume: 0.8, shiftCut: Float(out.shiftCut),
                                    limiter: out.limiter ? 1 : 0, popCounter: pt.popCounter, blowoffCounter: pt.blowoffCounter))
        let t0 = CFAbsoluteTimeGetCurrent()
        kernel.render(frames: block, left: lbuf, right: rbuf)
        renderTime += CFAbsoluteTimeGetCurrent() - t0
        var sum = 0.0; var pk: Float = 0
        for i in 0..<block { L.append(lbuf[i]); R.append(rbuf[i]); sum += Double(lbuf[i] * lbuf[i]); pk = max(pk, abs(lbuf[i])) }
        var s = segStats[label] ?? (0, 0, 0)
        s.0 += sum; s.1 = max(s.1, pk); s.2 += block
        segStats[label] = s
    }
    writeWav(outDir.appendingPathComponent("\(def.id)-\(scenario.id).wav"), L, R)
    let dur = Double(L.count) / sr
    print(String(format: "%-16@ cpu %.1f%%  maxRpm %5.0f  maxGear %d", def.id as NSString, renderTime / dur * 100, maxRpm, maxGear))
    for seg in scenario.segments.map(\.label).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
        if let s = segStats[seg] {
            print(String(format: "    %-16@ rms %6.1f dB  peak %.2f", seg as NSString, 10 * log10(s.0 / Double(s.2) + 1e-12), s.1))
        }
    }
}
