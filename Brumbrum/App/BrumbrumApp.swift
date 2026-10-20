import SwiftUI

@main
struct BrumbrumApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.orange)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var showHearingNotice = false

    var body: some View {
        TabView(selection: $tab) {
            DriveView()
                .tabItem { Label("Drive", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(0)
            Group {
                if model.isMovingLive { LockedView() } else { GarageView() }
            }
            .tabItem { Label("Garage", systemImage: "car.side") }
            .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .onAppear { showHearingNotice = !model.settings.hearingNoticeShown }
        .alert("Mind the volume", isPresented: $showHearingNotice) {
            Button("Understood") { model.settings.hearingNoticeShown = true }
        } message: {
            Text("A note loud enough to beat road noise can mask sirens, horns and the car's own warnings, and sustained loud exposure on long drives harms hearing. Output is capped; keep it modest.")
        }
    }
}

/// Garage and Editor lock out above walking pace.
struct LockedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 56))
            Text("Choose engines before setting off")
                .font(.title2.bold())
            Text("The Garage and Editor are locked while the car is moving. Use the Drive screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
