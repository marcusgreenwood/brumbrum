import Foundation
import AVFoundation

/// Owns the audio session and graph:
/// `AVAudioSourceNode` → EQ → brickwall limiter → main mixer → output.
///
/// Mixes with whatever else is playing (`.mixWithOthers`, never `.duckOthers`)
/// so music and navigation keep the media source.
final class AudioController {
    enum Event { case interruptionBegan, interruptionEnded(shouldResume: Bool), deviceLost, routeChanged, configurationChanged }

    let controls: TripleBuffer<ControlFrame>
    private(set) var kernel: SynthKernel?
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let limiter: AVAudioUnitEffect = {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }()
    private var observers: [NSObjectProtocol] = []
    var onEvent: ((Event) -> Void)?

    private(set) var grantedSampleRate: Double = 0
    private(set) var grantedBufferDuration: Double = 0
    var isRunning: Bool { engine.isRunning }

    init(controls: TripleBuffer<ControlFrame>) {
        self.controls = controls
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            self?.handleInterruption(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            self?.handleRouteChange(n)
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(.configurationChanged)
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setPreferredSampleRate(48000)
        try? s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
        // Read back what was actually granted rather than assuming.
        grantedSampleRate = s.sampleRate
        grantedBufferDuration = s.ioBufferDuration
    }

    /// Builds (or rebuilds) the graph at the hardware rate and starts it.
    /// Returns the new kernel so the caller can load a program into it.
    @discardableResult
    func start(makeProgram: (Double) -> SynthProgram) throws -> SynthKernel {
        try configureSession()
        if engine.isRunning { engine.stop() }
        teardownGraph()

        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        let sr = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : grantedSampleRate
        let k = SynthKernel(sampleRate: sr, controls: controls)
        k.setProgram(makeProgram(sr))
        kernel = k

        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned(unsafe) k] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            k.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        source = node

        // Gentle default EQ: tame sub rumble and a touch of presence.
        eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 35; eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 120; eq.bands[1].bandwidth = 1; eq.bands[1].gain = 0; eq.bands[1].bypass = false
        eq.bands[2].filterType = .highShelf; eq.bands[2].frequency = 6000; eq.bands[2].gain = -2; eq.bands[2].bypass = false

        engine.attach(node)
        engine.attach(eq)
        engine.attach(limiter)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        configureLimiter()
        engine.prepare()
        try engine.start()
        return k
    }

    private func configureLimiter() {
        // AUPeakLimiter: fast attack, -1 dB pre-gain headroom.
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, -1, 0)
    }

    private func teardownGraph() {
        if let s = source {
            engine.disconnectNodeOutput(s)
            engine.detach(s)
        }
        if engine.attachedNodes.contains(eq) { engine.disconnectNodeOutput(eq); engine.detach(eq) }
        if engine.attachedNodes.contains(limiter) { engine.disconnectNodeOutput(limiter); engine.detach(limiter) }
        source = nil
    }

    func pause() { engine.pause() }

    func resume() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Lower-mid cut for cars whose DSP is bass-heavy; keyed off the route.
    func setRouteEQ(carPlay: Bool) {
        eq.bands[1].gain = carPlay ? -2 : 0
    }

    // MARK: Route identity

    static var currentRoute: (key: String, name: String, isCarPlay: Bool) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let o = outputs.first else { return ("none", "No output", false) }
        return ("\(o.portType.rawValue)|\(o.portName)", o.portName, o.portType == .carAudio)
    }

    // MARK: Notifications

    private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onEvent?(.interruptionBegan)
        case .ended:
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            onEvent?(.interruptionEnded(shouldResume: opts.contains(.shouldResume)))
        @unknown default: break
        }
    }

    private func handleRouteChange(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable: onEvent?(.deviceLost)
        case .newDeviceAvailable, .override, .routeConfigurationChange: onEvent?(.routeChanged)
        default: break
        }
    }
}
