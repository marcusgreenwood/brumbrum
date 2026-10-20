import SwiftUI

/// Audition every engine under simulated driving: scripted scenarios
/// (launch, cruise, kickdown, lift-off, braking, traffic…) or manual pedals.
struct TestDriveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickedScenario = DriveScenario.all[2]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        @Bindable var model = model
        let t = model.telemetry
        let engine = model.soundingEngine
        let running = model.mode == .testDrive && model.activeScenario != nil

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    enginePicker

                    // Gauges
                    HStack(alignment: .center, spacing: 16) {
                        RpmDial(rpm: running ? t.rpm : 0, redline: engine.range.redlineRpm,
                                gear: running ? (engine.drivetrain.isDirect ? 0 : t.gear) : -1,
                                limiter: t.limiter, shifting: t.shifting, compact: true)
                            .frame(width: 150, height: 150)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int((t.speed * 3.6).rounded()))")
                                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                                Text("km/h").foregroundStyle(.secondary)
                            }
                            meter("Load", value: t.load)
                            meter("Throttle", value: t.throttle, color: .green)
                            meter("Brake", value: t.brake, color: .red)
                            Text(String(format: "a %+.1f m/s²", t.accel))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }

                    // Progress
                    if let s = model.activeScenario {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(s.name).font(.headline)
                                Spacer()
                                Text(t.scenarioFinished ? "Finished" : t.scenarioLabel)
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                            }
                            if !s.isManual { ProgressView(value: t.scenarioProgress).tint(.orange) }
                        }
                        .padding(12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if model.activeScenario?.isManual == true { PedalPad() }

                    // Scenarios
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(DriveScenario.all + [DriveScenario.manual]) { s in
                            scenarioButton(s)
                        }
                    }

                    Toggle(isOn: $model.testAllEngines) {
                        VStack(alignment: .leading) {
                            Text("Cycle through every engine")
                            Text("When a scenario ends, switch to the next engine and replay it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 12) {
                        Button {
                            model.testAllEngines = true
                            if let first = model.library.all.first { model.selectEngine(first) }
                            model.startTestDrive(pickedScenario)
                        } label: {
                            Label("“\(pickedScenario.name)” on all engines", systemImage: "square.stack.3d.up.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(pickedScenario.isManual)

                        if running {
                            Button(role: .destructive) {
                                model.endTestDrive()
                            } label: {
                                Label("Stop", systemImage: "stop.fill").frame(minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Test drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        model.endTestDrive()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.toggleMute() } label: {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                }
            }
        }
    }

    private var enginePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.library.all) { e in
                    let selected = e.id == model.soundingEngine.id
                    Button {
                        model.selectEngine(e)
                    } label: {
                        Text(e.name)
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected ? Color.orange : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(selected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func scenarioButton(_ s: DriveScenario) -> some View {
        let active = model.activeScenario?.id == s.id && model.mode == .testDrive
        return Button {
            pickedScenario = s
            model.startTestDrive(s)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: s.icon).font(.title3)
                    Spacer()
                    Image(systemName: active ? "speaker.wave.2.fill" : "play.fill")
                        .foregroundStyle(active ? .orange : .secondary)
                }
                Text(s.name).font(.subheadline.bold()).multilineTextAlignment(.leading)
                Text(s.summary).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(10)
            .background(active ? Color.orange.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.orange : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(s.name)")
    }

    private func meter(_ title: String, value: Double, color: Color = .orange) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            if title == "Load" {
                SignedBar(value: value)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(color).frame(width: g.size.width * min(max(value, 0), 1))
                    }
                }
                .frame(height: 8)
            }
        }
    }
}

/// Press-and-hold pedals. Throttle depth follows how far up the pad you press.
struct PedalPad: View {
    @Environment(AppModel.self) private var model
    @State private var throttle = 0.0
    @State private var braking = false

    var body: some View {
        HStack(spacing: 12) {
            pedal(title: "BRAKE", color: .red, level: braking ? 1 : 0)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !braking { braking = true; model.setPedals(brake: 0.8) } }
                    .onEnded { _ in braking = false; model.setPedals(brake: 0) })

            GeometryReader { g in
                pedal(title: "THROTTLE", color: .green, level: throttle)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            throttle = min(max(1 - v.location.y / g.size.height, 0.05), 1)
                            model.setPedals(throttle: throttle)
                        }
                        .onEnded { _ in throttle = 0; model.setPedals(throttle: 0) })
            }
        }
        .frame(height: 180)
    }

    private func pedal(title: String, color: Color, level: Double) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.15))
            GeometryReader { g in
                VStack { Spacer(); RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.6)).frame(height: g.size.height * level) }
            }
            VStack {
                Spacer()
                Text(title).font(.headline.bold())
                Text(title == "THROTTLE" ? "hold — higher = harder" : "hold").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .contentShape(Rectangle())
    }
}
