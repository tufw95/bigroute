import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var isUpdateAvailable = false {
        didSet { onAvailabilityChange?(isUpdateAvailable) }
    }

    @ObservationIgnored
    var onAvailabilityChange: ((Bool) -> Void)?

    @ObservationIgnored
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    override init() {
        super.init()
        _ = controller
    }

    func checkForUpdates() {
        isUpdateAvailable = false
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            isUpdateAvailable = true
        }
    }
}
