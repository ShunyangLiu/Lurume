import Foundation
import Sparkle

/// The narrow surface used by menus and settings. Tests can replace Sparkle's
/// updater without starting a network request or touching its persisted state.
@MainActor
protocol UpdateEngine: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }

    func checkForUpdates()
}

extension SPUUpdater: UpdateEngine {}

/// Flushes user state before Sparkle begins replacing and relaunching the app.
@MainActor
struct UpdateInstallationSaveBoundary {
    let flushPendingLibrarySave: () -> Void
    let closeNoteEditor: () -> Void

    func prepareForInstallation() {
        flushPendingLibrarySave()
        closeNoteEditor()
    }
}

@MainActor
private final class LurumeUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var prepareForInstallation: (() -> Void)?

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        prepareForInstallation?()
    }
}

/// Owns Sparkle for the lifetime of the application without coupling update
/// infrastructure to reading, translation, or library state.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private(set) var standardController: SPUStandardUpdaterController?
    private let engine: any UpdateEngine
    private let sparkleDelegate: LurumeUpdaterDelegate?
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?

    var prepareForInstallation: (() -> Void)? {
        get { sparkleDelegate?.prepareForInstallation }
        set { sparkleDelegate?.prepareForInstallation = newValue }
    }

    init(startingUpdater: Bool = true) {
        let sparkleDelegate = LurumeUpdaterDelegate()
        let standardController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: sparkleDelegate,
            userDriverDelegate: nil
        )
        self.standardController = standardController
        self.sparkleDelegate = sparkleDelegate
        engine = standardController.updater

        synchronizeState()
        observeSparkleState(standardController.updater)

        if startingUpdater {
            standardController.startUpdater()
        }
    }

    init(engine: any UpdateEngine) {
        self.engine = engine
        standardController = nil
        sparkleDelegate = nil
        synchronizeState()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        engine.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard engine.automaticallyChecksForUpdates != enabled else { return }
        engine.automaticallyChecksForUpdates = enabled
        synchronizeState()
    }

    func synchronizeState() {
        canCheckForUpdates = engine.canCheckForUpdates
        automaticallyChecksForUpdates = engine.automaticallyChecksForUpdates
    }

    private func observeSparkleState(_ updater: SPUUpdater) {
        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        automaticChecksObservation = updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
    }
}
