import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showWizard = false
    @State private var confirmReset = false
    @State private var showCarPreview = false

    var body: some View {
        @Bindable var model = model
        let s = model.telemetry.sensors
        NavigationStack {
            Form {
                Section {
                    Button { showWizard = true } label: { Label("Run calibration wizard", systemImage: "scope") }
                    status("Orientation", ok: s.calibrated || model.sensor.calibration != nil)
                    status("Forward axis", ok: s.forwardResolved || model.sensor.calibration?.forward != nil)
                    if s.mountMoved { Label("Mount moved — recalibrate", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    Button("Forget calibration", role: .destructive) { model.sensor.resetCalibration() }
                } header: { Text("Calibration") }

                Section {
                    LabeledContent("Current route", value: model.routeName)
                    LabeledContent("Latency", value: model.hasLatencyProfile ? "\(Int(model.currentLatency * 1000)) ms (measured)" : "not measured")
                    Button {
                        model.measureLatency()
                    } label: {
                        HStack {
                            Label("Measure with a sweep", systemImage: "waveform")
                            if model.measuringLatency { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.measuringLatency)
                    if let msg = model.latencyMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading) {
                        Text("Fallback latency: \(Int(model.settings.manualLatency * 1000)) ms").font(.subheadline)
                        Slider(value: $model.settings.manualLatency, in: 0...0.4, step: 0.005)
                    }
                    ForEach(model.settings.latencyByRoute.keys.sorted(), id: \.self) { key in
                        LabeledContent(key.components(separatedBy: "|").last ?? key,
                                       value: "\(Int((model.settings.latencyByRoute[key] ?? 0) * 1000)) ms")
                    }
                    .onDelete { idx in
                        let keys = model.settings.latencyByRoute.keys.sorted()
                        for i in idx { model.settings.latencyByRoute[keys[i]] = nil }
                    }
                    Toggle("Predictive rendering", isOn: $model.settings.predictive)
                } header: { Text("Latency") } footer: {
                    Text("Stationary, quiet cabin. The app plays a sweep through the car speakers and records it on the microphone. Stored per audio route. Prediction never looks further ahead than 250 ms.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Level \(Int(model.settings.level * 100))%").font(.subheadline)
                        Slider(value: $model.settings.level, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text("Hard ceiling \(Int(model.settings.ceiling * 100))%").font(.subheadline)
                        Slider(value: $model.settings.ceiling, in: 0.2...0.95)
                    }
                    Toggle("Speed-dependent level cap", isOn: $model.settings.speedCap)
                } header: { Text("Output") } footer: {
                    Text("The ceiling cannot be exceeded by the level control. The speed cap counters the car's own speed-dependent volume so the two don't compound. A brickwall limiter sits before the output.")
                }

                Section {
                    Toggle("Gradient compensation", isOn: $model.settings.gradientCompensation)
                    Button("Reset learned acceleration curve", role: .destructive) { confirmReset = true }
                } header: { Text("Estimation") } footer: {
                    Text("Uncorrected, a climb reads as extra load — arguably closer to true motor torque. Try both.")
                }

                Section {
                    Button { showCarPreview = true } label: { Label("Preview CarPlay gauges", systemImage: "car.rear.and.tire.marks") }
                } header: { Text("CarPlay") } footer: {
                    Text("The same dashboard shown on the car's screen, at the e-tron GT's wide 10.1\" aspect. Start a test drive first to see the needles move.")
                }

                Section {
                    LabeledContent("BLE OBD-II speed", value: "Not in this build")
                } header: { Text("Vehicle data") } footer: {
                    Text("Phase P4: only if latency tests show rpm smoothness needs it. Must be a BLE adapter; classic Bluetooth SPP will not pair with iOS.")
                }

                Section("Safety") {
                    Text("This app never touches the car's exterior AVAS sound. Keep the level modest: a note that beats road noise can also mask sirens, horns and the car's own warnings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showWizard) { CalibrationWizard() }
            .fullScreenCover(isPresented: $showCarPreview) { CarPreviewView() }
            .confirmationDialog("Reset the learned a_max curve?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { model.resetAMax() }
            }
        }
    }

    private func status(_ title: String, ok: Bool) -> some View {
        LabeledContent(title) {
            Label(ok ? "Done" : "Needed", systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .yellow)
        }
    }
}

/// 1. Orientation  2. Forward axis  3. Latency  4. Level
struct CalibrationWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var startedLive = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                ProgressView(value: Double(step), total: 3).tint(.orange)
                switch step {
                case 0:
                    stepView(title: "1 · Orientation",
                             text: "Mount the phone, keep the car stationary and hold still for three seconds. This captures the gravity vector.",
                             action: "Capture", run: { model.sensor.beginOrientationCalibration() })
                case 1:
                    stepView(title: "2 · Forward axis",
                             text: "Drive straight and accelerate firmly once. The app correlates the phone's acceleration with GPS speed to learn which way is forward.",
                             action: "Start listening", run: { model.sensor.beginForwardCalibration() })
                case 2:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("3 · Latency").font(.title2.bold())
                        Text("Stationary and quiet. A short sweep plays through the speakers and is recorded on the microphone.")
                        Button {
                            model.measureLatency()
                        } label: { Label(model.measuringLatency ? "Measuring…" : "Measure", systemImage: "waveform") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.measuringLatency)
                        if let m = model.latencyMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
                    }
                default:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("4 · Level").font(.title2.bold())
                        Text("At a typical cruising speed (with music, if that's how you'll use it), set the level just above road noise.")
                        Slider(value: $model.settings.level, in: 0...1)
                        Text("\(Int(model.settings.level * 100))% of a \(Int(model.settings.ceiling * 100))% ceiling").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Spacer()
                    Button(step == 3 ? "Finish" : "Next") {
                        if step == 3 { finish() } else { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() } } }
            .onAppear {
                if model.mode != .live { model.startLive(); startedLive = true }
            }
        }
    }

    private func stepView(title: String, text: String, action: String, run: @escaping () -> Void) -> some View {
        let phase = model.telemetry.sensors.phase
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(text)
            Button(action, action: run).buttonStyle(.borderedProminent)
            switch phase {
            case .orientation(let p): ProgressView("Hold still…", value: p)
            case .forward(let p): ProgressView("Accelerate firmly…", value: p)
            case .done: Label("Captured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .idle: EmptyView()
            }
            if !model.sensor.isMotionAvailable {
                Label("Motion sensors aren't available on this device (e.g. the Simulator).", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.yellow)
            }
        }
    }

    private func finish() {
        model.sensor.cancelCalibration()
        if startedLive { model.stopAll() }
        dismiss()
    }
}
