import SwiftUI

/// Fake instrument cluster for the CarPlay screen. Laid out for a wide display
/// (the e-tron GT's 10.1" MMI is roughly 2.1:1) but adapts to any CarPlay size.
struct CarDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var sim = GaugeSim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = model.telemetry
            let engine = model.soundingEngine
            let running = model.mode != .off
            let g = sim.step(t, engine: engine, running: running, now: ctx.date)

            GeometryReader { geo in
                let wide = geo.size.width / max(geo.size.height, 1) > 1.45
                let dial = min(geo.size.height * (wide ? 0.92 : 0.5), geo.size.width * (wide ? 0.32 : 0.48))
                ZStack {
                    background
                    if wide {
                        HStack(spacing: geo.size.width * 0.015) {
                            speedo(g, size: dial)
                            centre(g, engine: engine, running: running)
                                .frame(maxWidth: .infinity)
                            tacho(g, engine: engine, size: dial)
                        }
                        .padding(.horizontal, geo.size.width * 0.03)
                    } else {
                        VStack(spacing: 8) {
                            HStack { speedo(g, size: dial); tacho(g, engine: engine, size: dial) }
                            centre(g, engine: engine, running: running)
                        }
                        .padding(8)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.02), .black],
                           center: .center, startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
    }

    private func speedo(_ g: GaugeSim.Values, size: CGFloat) -> some View {
        ArcGauge(value: g.speedKph, maxValue: 320, majorStep: 40, labelScale: 1,
                 redFrom: nil, title: "km/h", readout: "\(Int(g.speedKph.rounded()))", accent: .cyan)
            .frame(width: size, height: size)
    }

    private func tacho(_ g: GaugeSim.Values, engine: EngineDefinition, size: CGFloat) -> some View {
        let maxRpm = (engine.range.redlineRpm / 1000).rounded(.up) * 1000 + 1000
        return ArcGauge(value: g.rpm, maxValue: maxRpm, majorStep: maxRpm > 10000 ? 2000 : 1000, labelScale: 1000,
                        redFrom: engine.range.redlineRpm, title: "×1000 rpm",
                        readout: g.gearText, accent: g.limiter ? .red : .orange, flash: g.shiftLight)
            .frame(width: size, height: size)
    }

    private func centre(_ g: GaugeSim.Values, engine: EngineDefinition, running: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(engine.name.uppercased())
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                statusBadge
            }

            // Power / regen meter, as on an EV cluster.
            VStack(spacing: 3) {
                SignedBar(value: g.load).frame(height: 10)
                HStack {
                    Text("REGEN").foregroundStyle(.cyan)
                    Spacer()
                    Text(String(format: "%+.0f%%", g.load * 100)).monospacedDigit()
                    Spacer()
                    Text("POWER").foregroundStyle(.orange)
                }
                .font(.system(size: 9, weight: .bold))
            }

            HStack(spacing: 10) {
                MiniGauge(title: "WATER", value: g.waterC, range: 40...130, warn: 112, unit: "°C")
                MiniGauge(title: "OIL", value: g.oilC, range: 40...150, warn: 130, unit: "°C")
                if engine.turbo != nil {
                    MiniGauge(title: "BOOST", value: g.boostBar, range: -0.8...(engine.turbo?.maxBoost ?? 1.5), warn: nil, unit: "bar")
                } else {
                    MiniGauge(title: "OIL P", value: g.oilBar, range: 0...7, warn: nil, unit: "bar")
                }
            }

            HStack(spacing: 14) {
                GMeter(g: g.gLong)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.2f g", g.gLong)).font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(model.mode == .testDrive ? (model.telemetry.scenarioFinished ? "Finished" : model.telemetry.scenarioLabel) : (running ? "Live" : "Engine off"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    if model.mode == .testDrive, let s = model.activeScenario, !s.isManual {
                        ProgressView(value: model.telemetry.scenarioProgress).tint(.orange).frame(width: 90)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, color): (String, Color) = model.muted ? ("MUTED", .red) : {
            switch model.mode {
            case .off: return ("OFF", .gray)
            case .live: return ("LIVE", .green)
            case .testDrive: return ("TEST", .orange)
            case .preview: return ("PREVIEW", .purple)
            }
        }()
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.85), in: Capsule())
    }
}

/// Integrates the purely cosmetic gauges (temperatures, boost, smoothed needles).
final class GaugeSim {
    struct Values {
        var speedKph = 0.0, rpm = 0.0, load = 0.0, gLong = 0.0
        var waterC = 20.0, oilC = 20.0, boostBar = -0.6, oilBar = 0.0
        var gearText = "–", limiter = false, shiftLight = false
    }

    private var v = Values()
    private var last = Date()

    func step(_ t: TelemetrySnapshot, engine: EngineDefinition, running: Bool, now: Date) -> Values {
        let dt = min(max(now.timeIntervalSince(last), 0), 0.1)
        last = now
        func follow(_ x: inout Double, _ target: Double, _ rate: Double) { x += (target - x) * min(dt * rate, 1) }

        follow(&v.speedKph, t.speed * 3.6, 8)
        follow(&v.rpm, running ? t.rpm : 0, running ? 18 : 3)
        follow(&v.load, running ? t.load : 0, 10)
        follow(&v.gLong, t.accel / 9.81, 6)

        // Temperatures warm towards operating temperature and creep up under load.
        let ambient = 20.0
        let waterTarget = running ? 90 + 8 * max(v.load, 0) : ambient
        let oilTarget = running ? 95 + 25 * max(v.load, 0) * (v.rpm / max(engine.range.redlineRpm, 1)) : ambient
        follow(&v.waterC, waterTarget, running ? 0.06 : 0.01)
        follow(&v.oilC, oilTarget, running ? 0.03 : 0.008)

        let maxBoost = engine.turbo?.maxBoost ?? 1
        let boostTarget = running ? (v.load > 0 ? maxBoost * v.load * min(1, v.rpm / (engine.range.idleRpm * 2.5)) : -0.6) : 0
        follow(&v.boostBar, boostTarget, engine.turbo?.spoolRate ?? 2)
        follow(&v.oilBar, running ? 1.5 + 4.5 * min(v.rpm / max(engine.range.redlineRpm, 1), 1) : 0, 4)

        v.limiter = running && t.limiter
        v.shiftLight = running && !engine.drivetrain.isDirect && t.rpm > (engine.drivetrain.upshiftRpm * 0.95)
        if !running { v.gearText = "P" }
        else if engine.drivetrain.isDirect { v.gearText = "D" }
        else if t.speed < 0.3 && t.load <= 0.05 { v.gearText = "N" }
        else { v.gearText = "\(max(t.gear, 1))" }
        return v
    }
}

/// A 240° sweep dial with ticks, numerals, red zone, needle and a centre readout.
struct ArcGauge: View {
    var value: Double
    var maxValue: Double
    var majorStep: Double
    var labelScale: Double
    var redFrom: Double?
    var title: String
    var readout: String
    var accent: Color
    var flash = false

    private let startDeg = 150.0
    private let sweepDeg = 240.0

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = s / 2 - s * 0.04
                    func ang(_ x: Double) -> Double { (startDeg + sweepDeg * min(max(x / maxValue, 0), 1)) * .pi / 180 }
                    func pt(_ a: Double, _ rad: Double) -> CGPoint { CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad) }

                    // Bezel
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(0.08)), lineWidth: s * 0.01)

                    // Value arc
                    var arc = Path()
                    arc.addArc(center: c, radius: r * 0.93, startAngle: .radians(ang(0)), endAngle: .radians(ang(value)), clockwise: false)
                    ctx.stroke(arc, with: .color(accent.opacity(0.35)), style: .init(lineWidth: s * 0.035, lineCap: .butt))

                    if let red = redFrom {
                        var rz = Path()
                        rz.addArc(center: c, radius: r * 0.93, startAngle: .radians(ang(red)), endAngle: .radians(ang(maxValue)), clockwise: false)
                        ctx.stroke(rz, with: .color(.red), style: .init(lineWidth: s * 0.035))
                    }

                    // Ticks and numerals
                    let minor = majorStep / 5
                    for x in stride(from: 0.0, through: maxValue + 0.001, by: minor) {
                        let major = abs(x.truncatingRemainder(dividingBy: majorStep)) < 0.001
                        var tick = Path()
                        tick.move(to: pt(ang(x), r * (major ? 0.80 : 0.86)))
                        tick.addLine(to: pt(ang(x), r * 0.90))
                        ctx.stroke(tick, with: .color(.white.opacity(major ? 0.9 : 0.4)), lineWidth: major ? s * 0.012 : s * 0.006)
                        if major {
                            let label = Text("\(Int(x / labelScale))")
                                .font(.system(size: s * 0.062, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                            ctx.draw(label, at: pt(ang(x), r * 0.68))
                        }
                    }

                    // Needle
                    let a = ang(value)
                    var needle = Path()
                    needle.move(to: pt(a + .pi, r * 0.12))
                    needle.addLine(to: pt(a + 0.025, r * 0.86))
                    needle.addLine(to: pt(a - 0.025, r * 0.86))
                    needle.closeSubpath()
                    ctx.fill(needle, with: .color(accent))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - s * 0.045, y: c.y - s * 0.045, width: s * 0.09, height: s * 0.09)),
                             with: .color(.white.opacity(0.9)))
                }
                VStack(spacing: 0) {
                    Spacer()
                    Text(readout)
                        .font(.system(size: s * 0.17, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(flash ? .red : .white)
                    Text(title)
                        .font(.system(size: s * 0.06, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, s * 0.06)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Small horizontal bar gauge: water, oil, boost.
struct MiniGauge: View {
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var warn: Double?
    var unit: String

    var body: some View {
        let frac = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        let hot = warn.map { value >= $0 } ?? false
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(hot ? Color.red : Color.white.opacity(0.85)).frame(width: max(g.size.width * frac, 3))
                }
            }
            .frame(height: 6)
            Text(unit == "bar" ? String(format: "%.1f %@", value, unit) : "\(Int(value.rounded()))\(unit)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .frame(minWidth: 60, maxWidth: 90)
    }
}

/// Longitudinal g dot: up for acceleration, down for braking.
struct GMeter: View {
    var g: Double
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 1)
                Circle().stroke(.white.opacity(0.12), lineWidth: 1).padding(s * 0.25)
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                Circle()
                    .fill(g >= 0 ? Color.orange : Color.cyan)
                    .frame(width: s * 0.18, height: s * 0.18)
                    .offset(y: -CGFloat(min(max(g, -1.2), 1.2) / 1.2) * s * 0.41)
            }
        }
    }
}

/// Compact cluster for CarPlay Dashboard and the instrument cluster, where space is tight.
struct CompactGaugeView: View {
    @Environment(AppModel.self) private var model
    @State private var sim = GaugeSim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let engine = model.soundingEngine
            let g = sim.step(model.telemetry, engine: engine, running: model.mode != .off, now: ctx.date)
            GeometryReader { geo in
                let s = min(geo.size.height * 0.95, geo.size.width * 0.48)
                HStack(spacing: 6) {
                    ArcGauge(value: g.rpm, maxValue: (engine.range.redlineRpm / 1000).rounded(.up) * 1000 + 1000,
                             majorStep: engine.range.redlineRpm > 10000 ? 2000 : 1000, labelScale: 1000,
                             redFrom: engine.range.redlineRpm, title: "rpm", readout: g.gearText,
                             accent: g.limiter ? .red : .orange, flash: g.shiftLight)
                        .frame(width: s, height: s)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(g.speedKph.rounded()))")
                            .font(.system(size: s * 0.3, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("km/h").font(.caption2).foregroundStyle(.secondary)
                        Text(engine.name).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.6)
                        SignedBar(value: g.load).frame(height: 6)
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(Color.black)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// On-phone preview of the CarPlay dashboard: rotated to landscape so it fills
/// the screen at roughly the e-tron GT's 1540×720 (≈2.1:1) shape.
struct CarPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let long = geo.size.height
            let short = geo.size.width
            let width = min(long, short * 2.14)
            CarDashboardView()
                .frame(width: width, height: width / 2.14)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 10) {
                        Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                        Menu {
                            ForEach(DriveScenario.all) { s in
                                Button(s.name) { model.startTestDrive(s) }
                            }
                            if model.mode == .testDrive { Button("Stop", role: .destructive) { model.endTestDrive() } }
                        } label: { Image(systemName: "play.circle.fill").font(.title) }
                    }
                    .padding(10)
                    .tint(.white.opacity(0.7))
                }
                .rotationEffect(.degrees(90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .statusBarHidden()
    }
}
