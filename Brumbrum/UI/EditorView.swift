import SwiftUI

/// Sliders grouped by config section, with preview audio running underneath so
/// every change is heard immediately. A/B against the unmodified engine.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: EngineDefinition
    let isNew: Bool
    @State private var def: EngineDefinition
    @State private var listenTo = 0           // 0 edited, 1 original
    @State private var problems: [String] = []
    @State private var anglesText = ""
    @State private var banksText = ""
    @State private var saveError: String?
    @State private var previewing = false

    init(original: EngineDefinition, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _def = State(initialValue: original)
        _anglesText = State(initialValue: original.geometry?.firingAngles.map { String(format: "%g", $0) }.joined(separator: ", ") ?? "")
        _banksText = State(initialValue: original.geometry?.bankOf.map(String.init).joined(separator: ", ") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $def.name)
                    HStack {
                        Button(previewing ? "Stop preview" : "Preview live") { togglePreview() }
                            .buttonStyle(.borderedProminent)
                            .tint(previewing ? .red : .orange)
                        Spacer()
                        Picker("Listen", selection: $listenTo) {
                            Text("A · Edited").tag(0)
                            Text("B · Original").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    if previewing {
                        Text("\(Int(model.telemetry.rpm)) rpm · \(model.telemetry.scenarioLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !problems.isEmpty {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
                    }
                }

                rangeSection
                if def.family == .combustion {
                    geometrySection
                    excitationSection
                    exhaustSection
                } else {
                    generatorSection
                }
                drivetrainSection
                intakeSection
                ordersSection
                turboSection
                mixSection
            }
            .navigationTitle(isNew ? "New engine" : "Edit engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!problems.isEmpty) }
            }
            .onChange(of: def) { _, _ in revalidate() }
            .onChange(of: listenTo) { _, _ in pushAudition() }
            .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Sections

    private var rangeSection: some View {
        Section("Range") {
            ParamSlider("Idle rpm", $def.range.idleRpm, 400...2000, step: 10)
            ParamSlider("Idle wander", $def.range.idleWanderRpm, 0...100, step: 1)
            ParamSlider("Redline", $def.range.redlineRpm, 3000...(def.family == .synthetic ? 16000 : 10000), step: 50)
            Picker("Limiter", selection: $def.range.limiter.mode) {
                Text("Hard cut").tag("hardCut")
                Text("Soft stutter").tag("softCut")
            }
            ParamSlider("Limiter Hz", $def.range.limiter.cutHz, 4...40, step: 1)
            ParamSlider("Limiter depth", $def.range.limiter.depth, 0...1)
        }
    }

    private var geometrySection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Firing angles (crank °)").font(.caption).foregroundStyle(.secondary)
                TextField("0, 90, 180…", text: $anglesText)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(applyGeometry)
            }
            VStack(alignment: .leading) {
                Text("Bank of each cylinder").font(.caption).foregroundStyle(.secondary)
                TextField("0, 1, 0, 1…", text: $banksText)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(applyGeometry)
            }
            Button("Apply geometry", action: applyGeometry)
        } header: { Text("Geometry") } footer: {
            Text("These two arrays carry the engine's identity. Same angles with bankOf 0,1,0,1,1,0,1,0 is a crossplane V8; 0,1,0,1,0,1,0,1 is a flatplane.")
        }
    }

    private var excitationSection: some View {
        Section("Excitation") {
            if def.excitation != nil {
                ParamSlider("Sharpness @ 0 load", optional(\.excitation!.grainSharpness.atZeroLoad), 0...1)
                ParamSlider("Sharpness @ full load", optional(\.excitation!.grainSharpness.atFullLoad), 0...1)
                ParamSlider("Gain @ 0 load", optional(\.excitation!.grainGain.atZeroLoad), 0...1)
                ParamSlider("Gain @ full load", optional(\.excitation!.grainGain.atFullLoad), 0...1.5)
                ParamSlider("Cylinder variance", optional(\.excitation!.cylinderVariance), 0...0.15, step: 0.001)
            }
        }
    }

    private var exhaustSection: some View {
        Section("Exhaust") {
            if let ex = def.exhaust {
                ParamSlider("Pipe length ms", optional(\.exhaust!.pipeLengthMs), 0...20, step: 0.1)
                ParamSlider("Pipe feedback", optional(\.exhaust!.pipeFeedback), 0...0.9)
                ForEach(ex.resonances.indices, id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text("Resonance \(i + 1)").font(.caption.bold())
                        ParamSlider("Hz", optional(\.exhaust!.resonances[i].hz), 40...3000, step: 5)
                        ParamSlider("Q", optional(\.exhaust!.resonances[i].q), 0.5...12, step: 0.1)
                        ParamSlider("Gain", optional(\.exhaust!.resonances[i].gain), 0...1.5)
                    }
                }
                if ex.overrun != nil {
                    ParamSlider("Crackle density", optional(\.exhaust!.overrun!.crackleDensity), 0...1)
                    ParamSlider("Crackle gain", optional(\.exhaust!.overrun!.gain), 0...1)
                    ParamSlider("Crackle threshold", optional(\.exhaust!.overrun!.thresholdLoad), -1...0)
                }
            }
        }
    }

    private var generatorSection: some View {
        Section("Generator") {
            if def.generator != nil {
                Picker("Type", selection: optionalString(\.generator!.type)) {
                    Text("FM").tag("fm"); Text("Detuned saw").tag("saw"); Text("Formant").tag("formant")
                }
                ParamSlider("Base order", optional(\.generator!.baseOrder), 0.5...12, step: 0.5)
                ParamSlider("FM ratio", optional(\.generator!.fmRatio), 0.25...6, step: 0.05)
                ParamSlider("FM index @ 0 load", optional(\.generator!.fmIndexAtZeroLoad), 0...6)
                ParamSlider("FM index @ full", optional(\.generator!.fmIndexAtFullLoad), 0...8)
                ParamSlider("Detune cents", optional(\.generator!.detuneCents), 0...50, step: 0.5)
                ParamSlider("Formant low Hz", optional(\.generator!.formantLowHz), 100...2000, step: 10)
                ParamSlider("Formant high Hz", optional(\.generator!.formantHighHz), 500...8000, step: 50)
                ParamSlider("Formant Q", optional(\.generator!.formantQ), 0.5...10, step: 0.1)
                ParamSlider("Gain", optional(\.generator!.gain), 0...1.2)
            }
        }
    }

    private var drivetrainSection: some View {
        Section("Drivetrain") {
            if def.drivetrain.isDirect {
                ParamSlider("Top speed km/h", Binding(get: { def.drivetrain.topSpeedKph ?? 250 }, set: { def.drivetrain.topSpeedKph = $0 }), 100...350, step: 5)
            } else {
                ForEach(def.drivetrain.gearRatios.indices, id: \.self) { i in
                    ParamSlider("Gear \(i + 1)", $def.drivetrain.gearRatios[i], 0.4...5, step: 0.01)
                }
                ParamSlider("Final drive", $def.drivetrain.finalDrive, 2...5, step: 0.01)
                ParamSlider("Upshift rpm", $def.drivetrain.upshiftRpm, 2000...def.range.redlineRpm, step: 50)
                ParamSlider("Downshift rpm", $def.drivetrain.downshiftRpm, 1000...6000, step: 50)
                ParamSlider("Shift ms", $def.drivetrain.shiftMs, 50...600, step: 10)
                ParamSlider("Launch slip", $def.drivetrain.launchSlip, 0...1)
            }
        }
    }

    private var intakeSection: some View {
        Section("Intake") {
            ParamSlider("Noise gain", $def.intake.noiseGain, 0...1)
            ParamSlider("Cutoff @ idle", $def.intake.cutoffHzAtIdle, 50...2000, step: 10)
            ParamSlider("Cutoff @ redline", $def.intake.cutoffHzAtRedline, 500...8000, step: 50)
            ParamSlider("Load sensitivity", $def.intake.loadSensitivity, 0...1.5)
        }
    }

    private var ordersSection: some View {
        Section {
            ForEach(def.orders.indices, id: \.self) { i in
                VStack(alignment: .leading) {
                    ParamSlider("Order", $def.orders[i].order, 0.5...16, step: 0.5)
                    ForEach(def.orders[i].gain.indices, id: \.self) { j in
                        ParamSlider("Gain @ \(Int(def.orders[i].gain[j][0])) rpm", $def.orders[i].gain[j][1], 0...1.5)
                    }
                }
            }
            .onDelete { def.orders.remove(atOffsets: $0) }
            Button("Add order") {
                def.orders.append(.init(order: 2, gain: [[def.range.idleRpm, 0.2], [def.range.redlineRpm, 0.3]]))
            }
            .disabled(def.orders.count >= 12)
        } header: { Text("Orders") } footer: { Text("Sine partials at multiples of crank rotation. Swipe to delete.") }
    }

    private var turboSection: some View {
        Section("Turbo") {
            Toggle("Turbocharged", isOn: Binding(get: { def.turbo != nil }, set: {
                def.turbo = $0 ? .init(spoolRate: 2, maxBoost: 1.2, whistleHzAtMaxBoost: 5000, blowoffGain: 0.6) : nil
            }))
            if def.turbo != nil {
                ParamSlider("Spool rate", optional(\.turbo!.spoolRate), 0.2...6)
                ParamSlider("Max boost", optional(\.turbo!.maxBoost), 0.2...2.5)
                ParamSlider("Whistle Hz", optional(\.turbo!.whistleHzAtMaxBoost), 1000...12000, step: 100)
                ParamSlider("Blow-off gain", optional(\.turbo!.blowoffGain), 0...1.2)
            }
        }
    }

    private var mixSection: some View {
        Section("Mix") {
            ParamSlider("Master gain", $def.mix.masterGain, 0...1)
            ParamSlider("Exhaust : intake", $def.mix.exhaustToIntake, 0...1)
            ParamSlider("Wind gain", $def.mix.windGain, 0...1)
        }
    }

    // MARK: Helpers

    /// Binding into an optional sub-struct that the view only shows when present.
    private func optional(_ kp: WritableKeyPath<EngineDefinition, Double>) -> Binding<Double> {
        Binding(get: { def[keyPath: kp] }, set: { def[keyPath: kp] = $0 })
    }

    private func optionalString(_ kp: WritableKeyPath<EngineDefinition, String>) -> Binding<String> {
        Binding(get: { def[keyPath: kp] }, set: { def[keyPath: kp] = $0 })
    }

    private func applyGeometry() {
        let angles = anglesText.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let banks = banksText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard var g = def.geometry else { return }
        g.firingAngles = angles
        g.bankOf = banks
        g.cylinders = angles.count
        g.banks = max((banks.max() ?? 0) + 1, 1)
        def.geometry = g
    }

    private func revalidate() {
        do { try def.validate(); problems = [] } catch let e as EngineValidationError { problems = e.problems } catch { problems = [error.localizedDescription] }
        pushAudition()
    }

    private func pushAudition() {
        guard previewing else { return }
        if listenTo == 1 { model.audition(original) } else if problems.isEmpty { model.audition(def) }
    }

    private func togglePreview() {
        if previewing {
            model.audition(nil)
            model.stopAll()
            previewing = false
        } else {
            previewing = true
            model.setPreview(auto: true)
            model.audition(listenTo == 1 ? original : def)
            model.startPreview()
        }
    }

    private func close() {
        if previewing { model.audition(nil); model.stopAll() }
        dismiss()
    }

    private func save() {
        do {
            try model.library.save(def)
            if previewing { model.audition(nil); model.stopAll() }
            model.selectEngine(def)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double? = nil) {
        self.title = title
        _value = value
        self.range = range.lowerBound < range.upperBound ? range : range.lowerBound...(range.lowerBound + 1)
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(formatted).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: clamped, in: range, step: step)
            } else {
                Slider(value: clamped, in: range)
            }
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 })
    }

    private var formatted: String {
        if let step, step >= 1 { return String(format: "%.0f", value) }
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }
}
