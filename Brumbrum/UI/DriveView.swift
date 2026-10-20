import SwiftUI

/// The only screen usable while moving: dark, huge targets, glanceable.
/// Tapping the dial mutes instantly.
struct DriveView: View {
    @Environment(AppModel.self) private var model
    @State private var showTestDrive = false
    @State private var showCarPreview = false

    var body: some View {
        let t = model.telemetry
        let engine = model.soundingEngine
        ScrollView {
            VStack(spacing: 18) {
                header(engine)
                banners

                RpmDial(rpm: model.mode == .off ? 0 : t.rpm, redline: engine.range.redlineRpm,
                        gear: model.mode == .off ? -1 : (engine.drivetrain.isDirect ? 0 : t.gear),
                        limiter: t.limiter, shifting: t.shifting)
                    .frame(maxWidth: 360)
                    .overlay(alignment: .bottom) {
                        if model.muted {
                            Label("MUTED", systemImage: "speaker.slash.fill")
                                .font(.headline)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(.red, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleMute() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(model.muted ? "Unmute" : "Mute")

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int((t.speed * 3.6).rounded()))")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("km/h").font(.title3).foregroundStyle(.secondary)
                }

                controls
                DiagnosticsStrip()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(isPresented: $showTestDrive) { TestDriveView() }
        .fullScreenCover(isPresented: $showCarPreview) { CarPreviewView() }
        .onAppear {
            // `-testDrive <scenario-id>` opens the test drive and starts it (handy for scripted checks).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-testDrive"), i + 1 < args.count,
               let s = DriveScenario.all.first(where: { $0.id == args[i + 1] }) {
                model.settings.hearingNoticeShown = true
                model.startTestDrive(s)
                if args.contains("-carPreview") { showCarPreview = true } else { showTestDrive = true }
            }
        }
    }

    private func header(_ engine: EngineDefinition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.name).font(.title.bold())
                Text(engine.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(model.routeName, systemImage: model.isCarPlay ? "car.fill" : "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
                Text("\(Int(model.currentLatency * 1000)) ms\(model.hasLatencyProfile ? "" : " (default)")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var banners: some View {
        let s = model.telemetry.sensors
        if let err = model.audioError {
            banner(err, icon: "exclamationmark.triangle.fill", color: .red)
        }
        if model.mode == .live {
            if s.mountMoved {
                banner("Phone moved on its mount. Sound faded out — recalibrate in Settings.", icon: "iphone.radiowaves.left.and.right", color: .red)
            } else if !s.calibrated || !s.forwardResolved {
                banner(!s.calibrated ? "Not calibrated. Run the calibration wizard in Settings." : "Forward axis unknown. Accelerate firmly once in a straight line (Settings → Calibration).",
                       icon: "scope", color: .yellow)
            }
            if !model.hasLatencyProfile {
                banner("No latency profile for \(model.routeName). Measure it in Settings.", icon: "timer", color: .yellow)
            }
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if model.mode == .live { model.stopAll() } else { model.startLive() }
                } label: {
                    Label(model.mode == .live ? "Engine off" : "Engine on",
                          systemImage: model.mode == .live ? "stop.fill" : "power")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.mode == .live ? .red : .green)

                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .font(.title2)
                        .frame(width: 72, height: 64)
                }
                .buttonStyle(.bordered)
                .tint(model.muted ? .red : .white)
            }

            Button {
                showTestDrive = true
            } label: {
                Label("Test drive — simulate acceleration, cruising, braking", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.isMovingLive)
        }
    }
}
