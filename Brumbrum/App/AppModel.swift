import Foundation
import Observation
import AVFoundation

struct AppSettings: Codable, Equatable {
    var selectedEngineID = "crossplane-v8"
    var level = 0.7
    var ceiling = 0.85                 // hard cap the level slider cannot exceed
    var speedCap = true
    var gradientCompensation = false
    var predictive = true
    var manualLatency = 0.15           // fallback when no route profile exists
    var latencyByRoute: [String: Double] = [:]
    var hearingNoticeShown = false
}

@Observable
final class AppModel {
    /// One model shared by the phone UI and the CarPlay scenes.
    static let shared = AppModel()

    let library = EngineLibrary()
    private(set) var telemetry = TelemetrySnapshot()
    var settings: AppSettings { didSet { if settings != oldValue { persistSettings(); pushConfig() } } }

    private(set) var mode: DriveMode = .off
    private(set) var muted = false
    private(set) var audioError: String?
    private(set) var routeName = AudioController.currentRoute.name
    private(set) var routeKey = AudioController.currentRoute.key
    private(set) var isCarPlay = AudioController.currentRoute.isCarPlay
    private(set) var measuringLatency = false
    var latencyMessage: String?

    // Test drive
    private(set) var activeScenario: DriveScenario?
    var testAllEngines = false
    private var modeBeforeTest: DriveMode = .off

    // Editor live preview
    private(set) var auditionDefinition: EngineDefinition?

    @ObservationIgnored private let audio: AudioController
    @ObservationIgnored private let loop: ControlLoop
    @ObservationIgnored private var engineSwapWork: DispatchWorkItem?

    static let settingsKey = "appSettings"

    init() {
        var s = AppSettings()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) { s = decoded }
        settings = s
        let controls = TripleBuffer(initial: ControlFrame())
        let initial = library.engine(id: s.selectedEngineID) ?? library.presets.first!
        audio = AudioController(controls: controls)
        loop = ControlLoop(controls: controls, engine: initial)
        loop.onTelemetry = { [weak self] snap in self?.receive(snap) }
        audio.onEvent = { [weak self] e in self?.handle(e) }
        pushConfig()
    }

    var selectedEngine: EngineDefinition {
        library.engine(id: settings.selectedEngineID) ?? library.presets.first!
    }

    /// The definition the synthesiser is actually playing.
    var soundingEngine: EngineDefinition { auditionDefinition ?? selectedEngine }

    var currentLatency: Double { settings.latencyByRoute[routeKey] ?? settings.manualLatency }
    var hasLatencyProfile: Bool { settings.latencyByRoute[routeKey] != nil }

    /// Garage and Editor lock out above walking pace.
    var isMovingLive: Bool { mode == .live && telemetry.speed > 2.0 }

    // MARK: Modes

    func startLive() {
        loop.sensor.gradientCompensation = settings.gradientCompensation
        loop.sensor.start()
        setMode(.live)
    }

    func stopAll() {
        activeScenario = nil
        setMode(.off)
        loop.sensor.stop()
    }

    func startPreview() { setMode(.preview) }

    func setPreview(rpm: Double? = nil, load: Double? = nil, auto: Bool? = nil) {
        loop.update { c in
            if let rpm { c.previewRpm = rpm }
            if let load { c.previewLoad = load }
            if let auto { c.previewAuto = auto }
        }
    }

    func startTestDrive(_ scenario: DriveScenario) {
        if mode != .testDrive { modeBeforeTest = mode }
        activeScenario = scenario
        loop.update { $0.manualThrottle = 0; $0.manualBrake = 0 }
        loop.startScenario(scenario)
        loop.setEngine(soundingEngine)
        setMode(.testDrive)
    }

    func endTestDrive() {
        activeScenario = nil
        testAllEngines = false
        setMode(modeBeforeTest == .testDrive ? .off : modeBeforeTest)
    }

    func setPedals(throttle: Double? = nil, brake: Double? = nil) {
        loop.update { c in
            if let throttle { c.manualThrottle = throttle }
            if let brake { c.manualBrake = brake }
        }
    }

    private func setMode(_ m: DriveMode) {
        mode = m
        loop.update { $0.mode = m; $0.fadeSeconds = 0.25; $0.suspended = false }
        if m == .off {
            // Fade, then stop the graph.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.mode == .off else { return }
                self.audio.stop()
                self.loop.stop()
            }
            return
        }
        loop.start()
        ensureAudioRunning()
    }

    private func ensureAudioRunning() {
        guard !audio.isRunning else { return }
        do {
            let def = soundingEngine
            try audio.start { sr in SynthProgram(definition: def, sampleRate: sr) }
            audio.setRouteEQ(carPlay: isCarPlay)
            audioError = nil
        } catch {
            audioError = "Audio failed to start: \(error.localizedDescription)"
        }
    }

    // MARK: Mute

    func toggleMute() { setMuted(!muted) }

    func setMuted(_ m: Bool) {
        muted = m
        loop.update { $0.muted = m; $0.fadeSeconds = m ? 0.03 : 0.4 }
    }

    // MARK: Engines

    func selectEngine(_ def: EngineDefinition) {
        settings.selectedEngineID = def.id
        auditionDefinition = nil
        load(def, crossfade: true)
    }

    /// Editor: play a modified definition live. Same-structure changes swap
    /// without a fade; structural changes fade through silence.
    func audition(_ def: EngineDefinition?) {
        let previous = soundingEngine
        auditionDefinition = def
        let target = def ?? selectedEngine
        let structural = previous.family != target.family
            || previous.geometry?.cylinders != target.geometry?.cylinders
            || previous.geometry?.banks != target.geometry?.banks
        load(target, crossfade: structural)
    }

    private func load(_ def: EngineDefinition, crossfade: Bool) {
        loop.setEngine(def)
        guard let kernel = audio.kernel, audio.isRunning else { return }
        engineSwapWork?.cancel()
        if !crossfade {
            kernel.setProgram(SynthProgram(definition: def, sampleRate: Double(kernel.sampleRate)))
            return
        }
        loop.update { $0.suspended = true; $0.fadeSeconds = 0.06 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let k = self.audio.kernel else { return }
            k.setProgram(SynthProgram(definition: def, sampleRate: Double(k.sampleRate)))
            self.loop.update { $0.suspended = false; $0.fadeSeconds = 0.15 }
        }
        engineSwapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func nextEngine(after def: EngineDefinition) -> EngineDefinition {
        let all = library.all
        guard let i = all.firstIndex(where: { $0.id == def.id }) else { return all[0] }
        return all[(i + 1) % all.count]
    }

    // MARK: Telemetry

    private func receive(_ snap: TelemetrySnapshot) {
        let wasFinished = telemetry.scenarioFinished
        telemetry = snap
        if mode == .testDrive, snap.scenarioFinished, !wasFinished, let s = activeScenario, testAllEngines {
            let next = nextEngine(after: selectedEngine)
            selectEngine(next)
            startTestDrive(s)
        }
    }

    // MARK: Settings

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    private func pushConfig() {
        let s = settings
        let latency = currentLatency
        loop.update { c in
            c.level = s.level
            c.ceiling = s.ceiling
            c.speedCap = s.speedCap
            c.predictive = s.predictive
            c.latency = latency
        }
        loop.sensor.gradientCompensation = s.gradientCompensation
    }

    func resetAMax() { loop.resetLearnedAMax() }

    var sensor: SensorEstimator { loop.sensor }

    // MARK: Latency

    func measureLatency() {
        guard !measuringLatency else { return }
        measuringLatency = true
        latencyMessage = "Measuring… keep the cabin quiet."
        let resumeMode = mode
        audio.stop()
        Task { @MainActor in
            do {
                let l = try await LatencyMeasurer.measure()
                refreshRoute()
                settings.latencyByRoute[routeKey] = l
                latencyMessage = String(format: "Measured %.0f ms on %@", l * 1000, routeName)
            } catch {
                latencyMessage = "\(error.localizedDescription) Using \(Int(settings.manualLatency * 1000)) ms."
            }
            measuringLatency = false
            if resumeMode != .off { ensureAudioRunning() }
        }
    }

    // MARK: Audio events

    private func refreshRoute() {
        let r = AudioController.currentRoute
        routeKey = r.key; routeName = r.name; isCarPlay = r.isCarPlay
        pushConfig()
    }

    private func handle(_ e: AudioController.Event) {
        switch e {
        case .interruptionBegan:
            // Fade out over ~100 ms, then stop.
            loop.update { $0.suspended = true; $0.fadeSeconds = 0.1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.audio.pause() }
        case .interruptionEnded(let shouldResume):
            guard shouldResume, mode != .off else { return }
            do {
                try audio.resume()
                // Never resume at full level.
                loop.update { $0.suspended = false; $0.fadeSeconds = 2.0 }
            } catch {
                audioError = error.localizedDescription
            }
        case .deviceLost:
            // Cable pulled: stop immediately rather than play out of the phone speaker.
            loop.update { $0.suspended = true; $0.fadeSeconds = 0.005 }
            audio.pause()
            refreshRoute()
            if mode == .live { mode = .off; loop.update { $0.mode = .off }; audio.stop() }
        case .routeChanged:
            refreshRoute()
            audio.setRouteEQ(carPlay: isCarPlay)
        case .configurationChanged:
            refreshRoute()
            guard mode != .off else { return }
            // Hardware format changed: rebuild the graph at the new rate.
            loop.update { $0.fadeSeconds = 0.5 }
            ensureAudioRunningAfterReconfigure()
        }
    }

    private func ensureAudioRunningAfterReconfigure() {
        let def = soundingEngine
        do {
            try audio.start { sr in SynthProgram(definition: def, sampleRate: sr) }
        } catch {
            audioError = error.localizedDescription
        }
    }
}
