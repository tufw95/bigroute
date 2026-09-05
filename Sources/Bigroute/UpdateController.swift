import Observation
import OSLog
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    var isUpdateAvailable = false {
        didSet { onAvailabilityChange?(isUpdateAvailable) }
    }
    private(set) var canCheckForUpdates = false
    private(set) var lastError: String?

    @ObservationIgnored var onAvailabilityChange: ((Bool) -> Void)?
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    override init() {
        super.init()
        do {
            try controller.updater.start()
            controller.updater.clearFeedURLFromUserDefaults()
            availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let available = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = available }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        lastError = nil
        // Sparkle brings an existing download/install session to the front.
        // Keep the update badge until the updater reports its actual result.
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              var components = URLComponents(string: feed) else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "check" }
        query.append(URLQueryItem(name: "check", value: UUID().uuidString))
        components.queryItems = query
        return components.url?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isUpdateAvailable = true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        isUpdateAvailable = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let value = error as NSError
        if value.domain == SUSparkleErrorDomain,
           [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError].contains(where: { Int($0.rawValue) == value.code }) { return }
        lastError = error.localizedDescription
        Logger(subsystem: "com.routerquota.app", category: "Updates")
            .error("Update failed domain=\(value.domain, privacy: .public) code=\(value.code, privacy: .public)")
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool { immediateFocus }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) { isUpdateAvailable = true }
}
