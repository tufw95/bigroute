import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    var isUpdateAvailable = false {
        didSet { onAvailabilityChange?(isUpdateAvailable) }
    }

    @ObservationIgnored
    var onAvailabilityChange: ((Bool) -> Void)?

    @ObservationIgnored
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
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

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard var components = URLComponents(string:
            "https://github.com/tufw95/bigroute/releases/download/office-channel/appcast.xml"
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "check", value: String(Int(Date().timeIntervalSince1970)))
        ]
        return components.url?.absoluteString
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
