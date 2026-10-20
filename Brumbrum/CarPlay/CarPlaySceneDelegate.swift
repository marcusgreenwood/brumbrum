import CarPlay
import SwiftUI
import Observation

/// Main CarPlay screen. A navigation-category app is the only kind CarPlay
/// lets draw its own content, so the gauges sit in the CPWindow under an
/// otherwise empty CPMapTemplate whose buttons control the app.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var model: AppModel { .shared }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.window = window

        let host = UIHostingController(rootView: CarDashboardView().environment(model))
        host.view.backgroundColor = .black
        window.rootViewController = host

        let map = CPMapTemplate()
        map.automaticallyHidesNavigationBar = false
        mapTemplate = map
        refreshButtons()
        interfaceController.setRootTemplate(map, animated: false, completion: nil)
        observeModel()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        self.interfaceController = nil
        self.window = nil
        mapTemplate = nil
    }

    // MARK: Buttons

    /// Re-applies button state whenever the model's mode or mute changes.
    private func observeModel() {
        withObservationTracking {
            _ = model.mode
            _ = model.muted
            _ = model.settings.selectedEngineID
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.mapTemplate != nil else { return }
                self.refreshButtons()
                self.observeModel()
            }
        }
    }

    private func refreshButtons() {
        guard let map = mapTemplate else { return }

        let power = CPMapButton { [weak self] _ in
            guard let self else { return }
            if self.model.mode == .off { self.model.startLive() } else { self.model.stopAll() }
        }
        power.image = symbol(model.mode == .off ? "power" : "stop.fill")

        let mute = CPMapButton { [weak self] _ in self?.model.toggleMute() }
        mute.image = symbol(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")

        let test = CPMapButton { [weak self] _ in self?.showScenarios() }
        test.image = symbol("play.circle.fill")

        map.mapButtons = [power, mute, test]

        let engine = CPBarButton(title: "Engine") { [weak self] _ in self?.showEngines() }
        map.leadingNavigationBarButtons = [engine]
        let testDrive = CPBarButton(title: model.mode == .testDrive ? "Stop test" : "Test drive") { [weak self] _ in
            guard let self else { return }
            if self.model.mode == .testDrive { self.model.endTestDrive() } else { self.showScenarios() }
        }
        map.trailingNavigationBarButtons = [testDrive]
    }

    private func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
    }

    // MARK: Lists

    private func showEngines() {
        func item(_ e: EngineDefinition) -> CPListItem {
            let selected = e.id == model.settings.selectedEngineID
            let item = CPListItem(text: e.name, detailText: e.summary,
                                  image: selected ? UIImage(systemName: "checkmark.circle.fill") : nil)
            item.handler = { [weak self] _, done in
                self?.model.selectEngine(e)
                done()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        var sections = [CPListSection(items: model.library.presets.map(item), header: "Presets", sectionIndexTitle: nil)]
        if !model.library.userEngines.isEmpty {
            sections.append(CPListSection(items: model.library.userEngines.map(item), header: "My engines", sectionIndexTitle: nil))
        }
        interfaceController?.pushTemplate(CPListTemplate(title: "Engine", sections: sections), animated: true, completion: nil)
    }

    private func showScenarios() {
        // A simulated drive while really driving would fight the live sound.
        if model.isMovingLive {
            let alert = CPAlertTemplate(titleVariants: ["Test drives are for when you're parked"],
                                        actions: [CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                                            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                                        }])
            interfaceController?.presentTemplate(alert, animated: true, completion: nil)
            return
        }
        var items: [CPListItem] = []
        if model.mode == .testDrive {
            let stop = CPListItem(text: "Stop test drive", detailText: nil, image: UIImage(systemName: "stop.fill"))
            stop.handler = { [weak self] _, done in
                self?.model.endTestDrive(); done()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            items.append(stop)
        }
        for s in DriveScenario.all {
            let item = CPListItem(text: s.name, detailText: s.summary, image: UIImage(systemName: s.icon))
            item.handler = { [weak self] _, done in
                self?.model.startTestDrive(s); done()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            items.append(item)
        }
        let all = CPListItem(text: "Full lap on every engine", detailText: "Cycles through all engines",
                             image: UIImage(systemName: "square.stack.3d.up.fill"))
        all.handler = { [weak self] _, done in
            guard let self else { return }
            self.model.testAllEngines = true
            if let first = self.model.library.all.first { self.model.selectEngine(first) }
            if let lap = DriveScenario.all.first(where: { $0.id == "lap" }) { self.model.startTestDrive(lap) }
            done()
            self.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        items.append(all)
        let list = CPListTemplate(title: "Test drive", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }
}

/// CarPlay Dashboard tile: a compact rev counter and speed.
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didConnect dashboardController: CPDashboardController,
                                           to window: UIWindow) {
        window.rootViewController = UIHostingController(rootView: CompactGaugeView().environment(AppModel.shared))
        let mute = CPDashboardButton(titleVariants: ["Mute engine"], subtitleVariants: ["Brumbrum"],
                                     image: UIImage(systemName: "speaker.slash.fill")!) { _ in
            AppModel.shared.toggleMute()
        }
        dashboardController.shortcutButtons = [mute]
    }

    func templateApplicationDashboardScene(_ scene: CPTemplateApplicationDashboardScene,
                                           didDisconnect dashboardController: CPDashboardController,
                                           from window: UIWindow) {
        window.rootViewController = nil
    }
}

/// Instrument cluster, on cars that offer CarPlay there.
final class CarPlayClusterSceneDelegate: UIResponder, CPTemplateApplicationInstrumentClusterSceneDelegate, CPInstrumentClusterControllerDelegate {
    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didConnect instrumentClusterController: CPInstrumentClusterController) {
        instrumentClusterController.delegate = self
    }

    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        instrumentClusterController.delegate = nil
    }

    func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) {
        instrumentClusterWindow.rootViewController = UIHostingController(rootView: CompactGaugeView().environment(AppModel.shared))
    }

    func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) {
        instrumentClusterWindow.rootViewController = nil
    }

    func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) {}
    func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) {}
}
