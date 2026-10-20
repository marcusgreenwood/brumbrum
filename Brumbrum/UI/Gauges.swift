import SwiftUI

/// Glanceable rev counter: arc, redline zone, needle, gear in the middle.
struct RpmDial: View {
    var rpm: Double
    var redline: Double
    var gear: Int
    var limiter: Bool
    var shifting: Bool
    var compact = false

    private let start = Angle.degrees(135)
    private let sweep = 270.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let maxRpm = (redline / 1000).rounded(.up) * 1000 + 1000
            ZStack {
                Canvas { ctx, sz in
                    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                    let r = size / 2 - size * 0.06
                    func angle(_ v: Double) -> Angle { .degrees(start.degrees + sweep * min(max(v / maxRpm, 0), 1)) }

                    var track = Path()
                    track.addArc(center: c, radius: r, startAngle: start, endAngle: angle(maxRpm), clockwise: false)
                    ctx.stroke(track, with: .color(.white.opacity(0.12)), style: .init(lineWidth: size * 0.05, lineCap: .round))

                    var red = Path()
                    red.addArc(center: c, radius: r, startAngle: angle(redline), endAngle: angle(maxRpm), clockwise: false)
                    ctx.stroke(red, with: .color(.red.opacity(0.7)), style: .init(lineWidth: size * 0.05, lineCap: .butt))

                    var fill = Path()
                    fill.addArc(center: c, radius: r, startAngle: start, endAngle: angle(rpm), clockwise: false)
                    let color: Color = limiter ? .red : (rpm > redline * 0.85 ? .orange : .white)
                    ctx.stroke(fill, with: .color(color), style: .init(lineWidth: size * 0.05, lineCap: .round))

                    if !compact {
                        let step = maxRpm > 10000 ? 2000.0 : 1000.0
                        for v in stride(from: 0.0, through: maxRpm, by: step) {
                            let a = angle(v).radians
                            let p = CGPoint(x: c.x + cos(a) * (r - size * 0.12), y: c.y + sin(a) * (r - size * 0.12))
                            ctx.draw(Text("\(Int(v / 1000))").font(.system(size: size * 0.06, weight: .semibold)).foregroundStyle(.secondary), at: p)
                        }
                    }
                }
                VStack(spacing: 0) {
                    Text(gear > 0 ? "\(gear)" : (gear == 0 ? "D" : "N"))
                        .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                        .foregroundStyle(shifting ? .orange : .white)
                        .contentTransition(.numericText())
                    Text("\(Int(rpm.rounded() / 10) * 10) rpm")
                        .font(.system(size: size * 0.07, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Horizontal bar for signed values in −1…1 (load).
struct SignedBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width / 2
            let v = min(max(value, -1), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Rectangle()
                    .fill(v >= 0 ? Color.orange : Color.cyan)
                    .frame(width: abs(v) * w)
                    .offset(x: v >= 0 ? w : w - abs(v) * w)
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1).offset(x: w)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// Collapsible live diagnostics: worth more than any other screen while developing.
struct DiagnosticsStrip: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let t = model.telemetry
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                    Text("Diagnostics").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { stat("speed", String(format: "%.1f m/s", t.speed)); stat("a_long", String(format: "%+.2f m/s²", t.accel)) }
                    GridRow { stat("rpm", String(format: "%.0f", t.rpm)); stat("load", String(format: "%+.2f", t.load)) }
                    GridRow { stat("jerk", String(format: "%+.1f", t.jerk)); stat("confidence", String(format: "%.2f", t.confidence)) }
                    GridRow { stat("horizon", String(format: "%.0f ms", t.predictionHorizon * 1000)); stat("gps", t.sensors.gpsSpeed >= 0 ? String(format: "%.1f ±%.1f", t.sensors.gpsSpeed, t.sensors.gpsAccuracy) : "—") }
                    GridRow { stat("gradient", String(format: "%+.1f°", t.sensors.gradientDeg)); stat("mode", t.mode.rawValue) }
                    GridRow { stat("bias", String(format: "%+.3f", t.sensors.bias)); stat("stopped", t.sensors.stationary ? "yes" : "no") }
                    GridRow { stat("σ speed", String(format: "%.2f", t.sensors.speedStdDev)); stat("gps Δ", String(format: "%+.2f", t.sensors.gpsInnovation)) }
                }
                .font(.system(.caption, design: .monospaced))
                SignedBar(value: t.load)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}
