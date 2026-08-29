import Sparkle

/// Owns Sparkle for the lifetime of the application without coupling update
/// infrastructure to reading, translation, or library state.
@MainActor
final class UpdaterController {
    let standardController: SPUStandardUpdaterController

    init(startingUpdater: Bool = false) {
        standardController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
