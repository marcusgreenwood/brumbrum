import SwiftUI
import UniformTypeIdentifiers

/// The preset list with a preview mode that drives the synthesiser from a
/// manual or automatic rpm ramp instead of the sensors.
struct GarageView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditorTarget?
    @State private var importing = false
    @State private var errorText: String?
    @State private var showTestDrive = false
    @State private var manualRpm = 2000.0
    @State private var manualLoad = 0.5
    @State private var auto = true

    struct EditorTarget: Identifiable {
        var def: EngineDefinition
        var isNew: Bool
        var id: String { def.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.mode == .preview { previewPanel }

                Section("Presets") {
                    ForEach(model.library.presets) { row($0, isPreset: true) }
                }
                Section {
                    if model.library.userEngines.isEmpty {
                        Text("Edit a preset to create your own. Engines are plain JSON files you can export and share.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.library.userEngines) { row($0, isPreset: false) }
                } header: { Text("My engines") }

                if !model.library.loadErrors.isEmpty {
                    Section("Load errors") {
                        ForEach(model.library.loadErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Garage")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTestDrive = true } label: { Label("Test drive", systemImage: "play.circle") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let def = try model.library.importEngine(from: result.get())
                    model.selectEngine(def)
                } catch {
                    errorText = error.localizedDescription
                }
            }
            .sheet(item: $editing) { target in
                EditorView(original: target.def, isNew: target.isNew)
            }
            .fullScreenCover(isPresented: $showTestDrive) { TestDriveView() }
            .alert("Couldn't import", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    private func row(_ e: EngineDefinition, isPreset: Bool) -> some View {
        let selected = e.id == model.settings.selectedEngineID
        let previewing = model.mode == .preview && selected
        return HStack(spacing: 12) {
            Button {
                model.selectEngine(e)
            } label: {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.body.weight(.semibold))
                        Text(e.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if previewing { model.stopAll() } else {
                    model.selectEngine(e)
                    model.setPreview(rpm: manualRpm, load: manualLoad, auto: auto)
                    model.startPreview()
                }
            } label: {
                Image(systemName: previewing ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                    .font(.title)
                    .foregroundStyle(previewing ? .red : .orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewing ? "Stop preview" : "Preview \(e.name)")
        }
        .swipeActions(edge: .trailing) {
            if !isPreset {
                Button(role: .destructive) { model.library.delete(e) } label: { Label("Delete", systemImage: "trash") }
            }
            Button {
                editing = isPreset ? EditorTarget(def: model.library.duplicate(e), isNew: true) : EditorTarget(def: e, isNew: false)
            } label: { Label(isPreset ? "Duplicate & edit" : "Edit", systemImage: "slider.horizontal.3") }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                editing = isPreset ? EditorTarget(def: model.library.duplicate(e), isNew: true) : EditorTarget(def: e, isNew: false)
            } label: { Label(isPreset ? "Duplicate & edit" : "Edit", systemImage: "slider.horizontal.3") }
            if let url = try? model.library.exportURL(for: e) {
                ShareLink(item: url) { Label("Export JSON", systemImage: "square.and.arrow.up") }
            }
            if !isPreset {
                Button(role: .destructive) { model.library.delete(e) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var previewPanel: some View {
        let e = model.soundingEngine
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Previewing \(e.name)").font(.headline)
                    Spacer()
                    Button("Stop") { model.stopAll() }.buttonStyle(.bordered).tint(.red)
                }
                Toggle("Automatic rpm ramp", isOn: $auto)
                    .onChange(of: auto) { _, v in model.setPreview(auto: v) }
                if auto {
                    HStack {
                        Text(model.telemetry.scenarioLabel).foregroundStyle(.orange)
                        Spacer()
                        Text("\(Int(model.telemetry.rpm)) rpm").monospacedDigit()
                    }
                    .font(.subheadline)
                } else {
                    VStack(alignment: .leading) {
                        Text("RPM \(Int(manualRpm))").font(.caption)
                        Slider(value: $manualRpm, in: e.range.idleRpm...e.range.redlineRpm)
                            .onChange(of: manualRpm) { _, v in model.setPreview(rpm: v) }
                        Text(String(format: "Load %+.2f", manualLoad)).font(.caption)
                        Slider(value: $manualLoad, in: -1...1)
                            .onChange(of: manualLoad) { _, v in model.setPreview(load: v) }
                    }
                }
            }
        } header: { Text("Preview") }
    }
}
